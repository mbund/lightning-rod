package dev.lightningrod.registry;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.level.block.LiquidBlock;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.util.valueproviders.IntProvider;
import net.minecraft.util.valueproviders.ConstantInt;
import net.minecraft.util.valueproviders.UniformInt;
import net.minecraft.world.level.block.DropExperienceBlock;
import net.minecraft.world.level.block.RedStoneOreBlock;
import net.minecraft.world.level.block.SculkCatalystBlock;
import net.minecraft.world.level.block.SculkSensorBlock;
import net.minecraft.world.level.block.SculkShriekerBlock;
import net.minecraft.world.level.block.SpawnerBlock;
import net.minecraft.core.Direction;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.IceBlock;
import net.minecraft.world.level.material.FlowingFluid;

final class PhysicsSnapshot {
    static void write(Path destination) throws Exception {
        Files.createDirectories(destination.toAbsolutePath().getParent());
        var shapes = new LinkedHashMap<List<AABB>, Integer>();
        var collisions = new ArrayList<int[]>();
        var context = new SpawnContext();
        var offsets = new ArrayList<net.minecraft.world.phys.Vec3>();
        for (var state : Block.BLOCK_STATE_REGISTRY) {
            int[] indices = new int[3];
            var offset = net.minecraft.world.phys.Vec3.ZERO;
            if (state.hasOffsetFunction()) {
                var originShape = state.getCollisionShape(EmptyBlockGetter.INSTANCE, BlockPos.ZERO, context);
                var displacedShape = state.getCollisionShape(EmptyBlockGetter.INSTANCE, new BlockPos(16, 0, 8), context);
                if (!originShape.toAabbs().equals(displacedShape.toAabbs())) offset = state.getOffset(BlockPos.ZERO);
            }
            offsets.add(offset);
            for (int i = 0; i < indices.length; i++) {
                var boxes = List.copyOf(state.getCollisionShape(EmptyBlockGetter.INSTANCE, new BlockPos(0, i - 2, 0), context).move(-offset.x, -offset.y, -offset.z).toAabbs());
                indices[i] = shapes.computeIfAbsent(boxes, key -> shapes.size());
            }
            collisions.add(indices);
        }
        int boxCount = shapes.keySet().stream().mapToInt(List::size).sum();
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(destination)))) {
            output.write("LRPHYS05".getBytes(StandardCharsets.US_ASCII));
            output.writeInt(Block.BLOCK_STATE_REGISTRY.size());
            output.writeInt(shapes.size());
            output.writeInt(boxCount);
            int stateIndex = 0;
            Direction[] faces = { Direction.WEST, Direction.EAST, Direction.NORTH, Direction.SOUTH, Direction.DOWN, Direction.UP };
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                var fluid = state.getFluidState();
                output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(state.getBlock().getFriction())));
                output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(state.getBlock().getSpeedFactor())));
                output.writeByte(fluid.is(FluidTags.WATER) ? 1 : fluid.is(FluidTags.LAVA) ? 2 : 0);
                output.writeByte(fluid.getAmount());
                int flags = state.blocksMotion() ? 1 : 0;
                if (!fluid.isEmpty() && fluid.hasProperty(FlowingFluid.FALLING) && fluid.getValue(FlowingFluid.FALLING)) flags |= 2;
                if (state.getBlock() instanceof IceBlock) flags |= 4;
                if (state.is(net.minecraft.world.level.block.Blocks.WATER) || state.is(net.minecraft.world.level.block.Blocks.BUBBLE_COLUMN)) flags |= 8;
                if (Block.isFaceFull(state.getCollisionShape(EmptyBlockGetter.INSTANCE, BlockPos.ZERO), Direction.UP)) flags |= 16;
                if (state.isAir()) flags |= 32;
                if (state.getBlock() instanceof LiquidBlock) flags |= 64;
                output.writeByte(flags);
                int sturdy = 0;
                for (int i = 0; i < faces.length; i++) if (state.isFaceSturdy(EmptyBlockGetter.INSTANCE, BlockPos.ZERO, faces[i])) sturdy |= 1 << i;
                output.writeByte(sturdy);
                for (int shape : collisions.get(stateIndex)) {
                    if (shape > 65535) throw new IllegalStateException("Too many spawn collision shapes");
                    output.writeShort(Short.reverseBytes((short)shape));
                }
                var offset = offsets.get(stateIndex++);
                output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits((float)-offset.x)));
                output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits((float)-offset.y)));
            }
            int boxOffset = 0;
            for (var boxes : shapes.keySet()) {
                if (boxes.size() > 65535) throw new IllegalStateException("Too many collision boxes");
                output.writeInt(Integer.reverseBytes(boxOffset));
                output.writeShort(Short.reverseBytes((short)boxes.size()));
                boxOffset += boxes.size();
            }
            for (var boxes : shapes.keySet()) for (var box : boxes) {
                for (double coordinate : new double[]{box.minX, box.minY, box.minZ, box.maxX, box.maxY, box.maxZ})
                    output.writeLong(Long.reverseBytes(Double.doubleToRawLongBits(coordinate)));
            }
            output.writeInt(BuiltInRegistries.BLOCK.size());
            for (var block : BuiltInRegistries.BLOCK) {
                IntProvider range = null;
                if (block instanceof DropExperienceBlock || block instanceof SculkCatalystBlock) {
                    Class<?> owner = block instanceof DropExperienceBlock ? DropExperienceBlock.class : SculkCatalystBlock.class;
                    for (var field : owner.getDeclaredFields()) if (IntProvider.class.isAssignableFrom(field.getType())) {
                        if (range != null) throw new IllegalStateException("Multiple block experience providers");
                        field.setAccessible(true);
                        range = (IntProvider)field.get(block);
                    }
                    if (range == null) throw new IllegalStateException("Missing block experience provider");
                }
                // These callbacks construct their providers inside spawnAfterBreak.
                if (block instanceof RedStoneOreBlock) range = UniformInt.of(1, 5);
                if (block instanceof SculkSensorBlock || block instanceof SculkShriekerBlock) range = ConstantInt.of(5);
                if (range != null && !(range instanceof ConstantInt) && !(range instanceof UniformInt)) throw new IllegalStateException("Unsupported block experience distribution");
                // Spawner callbacks bypass enchantment processing.
                boolean spawner = block instanceof SpawnerBlock;
                int minimum = spawner ? 15 : range == null ? 0 : PhysicsApi.minimum(range);
                int maximum = range == null ? minimum : PhysicsApi.maximum(range);
                if (minimum < 0 || maximum > 255 || maximum - minimum >= 255) throw new IllegalStateException("Block experience exceeds snapshot bounds");
                output.writeByte(minimum);
                output.writeByte(spawner ? 15 : maximum > minimum ? maximum - minimum + 1 : 0);
                output.writeByte(spawner ? 2 : maximum > minimum ? 1 : 0);
                output.writeByte(range != null ? 1 : 0);
            }
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                int rendering = state.canOcclude() && LightingApi.opacity(state) == 15 && Block.isShapeFullBlock(state.getOcclusionShape()) ? 1 : 0;
                if (state.hasBlockEntity()) rendering |= 2;
                String name = BuiltInRegistries.BLOCK.getKey(state.getBlock()).getPath();
                if (name.equals("beacon")) rendering |= 4;
                if (name.equals("end_gateway")) rendering |= 8;
                if (name.equals("structure_block") || name.equals("test_instance_block")) rendering |= 16;
                output.writeByte(rendering);
            }
        }
    }
}
