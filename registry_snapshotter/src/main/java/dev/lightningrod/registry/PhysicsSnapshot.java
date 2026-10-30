package dev.lightningrod.registry;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
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
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(destination)))) {
            output.write("LRPHYS03".getBytes(StandardCharsets.US_ASCII));
            output.writeInt(Block.BLOCK_STATE_REGISTRY.size());
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
                output.writeByte(flags);
                int sturdy = 0;
                for (int i = 0; i < faces.length; i++) if (state.isFaceSturdy(EmptyBlockGetter.INSTANCE, BlockPos.ZERO, faces[i])) sturdy |= 1 << i;
                output.writeByte(sturdy);
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
        }
    }
}
