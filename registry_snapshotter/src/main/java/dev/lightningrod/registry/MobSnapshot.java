package dev.lightningrod.registry;

import java.io.DataOutputStream;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.ai.attributes.DefaultAttributes;
import net.minecraft.world.item.SpawnEggItem;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.BaseRailBlock;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.DoorBlock;
import net.minecraft.world.level.block.FenceGateBlock;
import net.minecraft.world.level.block.LeavesBlock;
import net.minecraft.world.level.block.TrapDoorBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.pathfinder.PathComputationType;
import net.minecraft.world.level.pathfinder.WalkNodeEvaluator;

/// What mobs read that block and entity tags cannot tell: block state methods and classes, the
/// path type vanilla gives each state alone (so the port can be checked against it), entity
/// dimensions, tracking and default attributes, and the entity each spawn egg makes. Methods that
/// moved between releases are found by reflection, and only the gameplay baseline must have them.
final class MobSnapshot {
    static void write(DataOutputStream output) throws Exception {
        String release = System.getProperty("mcc.minecraftVersion");
        boolean baseline = "1.21.8".equals(release);
        Method solid = method(BlockState.class, "isSolid");
        Method solidRender = method(BlockState.class, "isSolidRender");
        Method pathType = null;
        try {
            pathType = WalkNodeEvaluator.class.getDeclaredMethod("getPathTypeFromState", BlockGetter.class, BlockPos.class);
            pathType.setAccessible(true);
        } catch (NoSuchMethodException missing) {
            if (baseline) throw missing;
        }
        if (baseline && (solid == null || solidRender == null)) throw new IllegalStateException("Missing block state methods");
        output.writeInt(Block.BLOCK_STATE_REGISTRY.size());
        for (var state : Block.BLOCK_STATE_REGISTRY) {
            var block = state.getBlock();
            int flags = 0;
            if (solid != null && (boolean)solid.invoke(state)) flags |= 1;
            if (solidRender != null && (boolean)solidRender.invoke(state)) flags |= 2;
            if (state.isPathfindable(PathComputationType.LAND)) flags |= 4;
            if (state.isPathfindable(PathComputationType.WATER)) flags |= 8;
            if (state.isPathfindable(PathComputationType.AIR)) flags |= 16;
            if (block instanceof DoorBlock door) {
                flags |= 32;
                if (state.getValue(DoorBlock.OPEN)) flags |= 64;
                if (door.type().canOpenByHand()) flags |= 128;
            }
            if (block instanceof BaseRailBlock) flags |= 256;
            if (block instanceof LeavesBlock) flags |= 512;
            if (block instanceof FenceGateBlock) {
                flags |= 1024;
                if (state.getValue(FenceGateBlock.OPEN)) flags |= 2048;
            }
            if (block instanceof TrapDoorBlock) flags |= 4096;
            if (state.isSuffocating(alone(state), BlockPos.ZERO)) flags |= 8192;
            output.writeShort(Short.reverseBytes((short)flags));
            output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(block.getJumpFactor())));
            output.writeByte(pathType == null ? 255 : ((Enum<?>)pathType.invoke(null, alone(state), BlockPos.ZERO)).ordinal());
        }
        output.writeInt(BuiltInRegistries.ENTITY_TYPE.size());
        for (var type : BuiltInRegistries.ENTITY_TYPE) {
            var dimensions = type.getDimensions();
            output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(dimensions.width())));
            output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(dimensions.height())));
            output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits(dimensions.eyeHeight())));
            boolean living = DefaultAttributes.hasSupplier(type);
            int flags = dimensions.fixed() ? 1 : 0;
            if (type.fireImmune()) flags |= 2;
            if (type.trackDeltas()) flags |= 4;
            if (type.canSummon()) flags |= 8;
            if (living) flags |= 16;
            output.writeByte(flags);
            output.writeByte(type.getCategory().ordinal());
            if (type.clientTrackingRange() > 255) throw new IllegalStateException("Tracking exceeds snapshot bounds");
            output.writeByte(type.clientTrackingRange());
            output.writeInt(Integer.reverseBytes(type.updateInterval()));
            if (!living) {
                output.writeByte(0);
                continue;
            }
            @SuppressWarnings("unchecked")
            var supplier = DefaultAttributes.getSupplier((EntityType<? extends LivingEntity>)type);
            int count = 0;
            for (var attribute : BuiltInRegistries.ATTRIBUTE) if (supplier.hasAttribute(BuiltInRegistries.ATTRIBUTE.wrapAsHolder(attribute))) count++;
            if (count > 255) throw new IllegalStateException("Too many default attributes");
            output.writeByte(count);
            for (var attribute : BuiltInRegistries.ATTRIBUTE) {
                var holder = BuiltInRegistries.ATTRIBUTE.wrapAsHolder(attribute);
                if (!supplier.hasAttribute(holder)) continue;
                output.writeShort(Short.reverseBytes((short)BuiltInRegistries.ATTRIBUTE.getId(attribute)));
                output.writeLong(Long.reverseBytes(Double.doubleToRawLongBits(supplier.getBaseValue(holder))));
            }
        }
        var eggs = new java.util.ArrayList<int[]>();
        for (var item : BuiltInRegistries.ITEM) {
            if (!(item instanceof SpawnEggItem)) continue;
            EntityType<?> type = null;
            for (Class<?> owner = item.getClass(); owner != null && type == null; owner = owner.getSuperclass())
                for (var field : owner.getDeclaredFields())
                    if (field.getType() == EntityType.class && !java.lang.reflect.Modifier.isStatic(field.getModifiers())) {
                        field.setAccessible(true);
                        type = (EntityType<?>)field.get(item);
                        break;
                    }
            if (type == null) {
                if (baseline) throw new IllegalStateException("Spawn egg without an entity type");
                continue;
            }
            eggs.add(new int[] { BuiltInRegistries.ITEM.getId(item), BuiltInRegistries.ENTITY_TYPE.getId(type) });
        }
        output.writeInt(eggs.size());
        for (int[] egg : eggs) {
            output.writeInt(Integer.reverseBytes(egg[0]));
            output.writeInt(Integer.reverseBytes(egg[1]));
        }
        // Mth's tables, computed as Mth computes them, since the JVM's sine and arcsine round
        // differently in the last place from other libraries and mobs turn by these.
        for (int i = 0; i < 65536; i++) output.writeInt(Integer.reverseBytes(Float.floatToRawIntBits((float)Math.sin(i * Math.PI * 2.0 / 65536.0))));
        for (int i = 0; i < 257; i++) {
            double angle = Math.asin(i / 256.0);
            output.writeLong(Long.reverseBytes(Double.doubleToRawLongBits(angle)));
            output.writeLong(Long.reverseBytes(Double.doubleToRawLongBits(Math.cos(angle))));
        }
    }

    private static Method method(Class<?> owner, String name) {
        try {
            return owner.getMethod(name);
        } catch (NoSuchMethodException missing) {
            return null;
        }
    }

    /// A world of one block at the origin, with air around, for methods that read a block getter.
    private static BlockGetter alone(BlockState state) {
        InvocationHandler handler = (proxy, method, arguments) -> switch (method.getName()) {
            case "getBlockState" -> ((BlockPos)arguments[0]).equals(BlockPos.ZERO) ? state : net.minecraft.world.level.block.Blocks.AIR.defaultBlockState();
            case "getFluidState" -> ((BlockPos)arguments[0]).equals(BlockPos.ZERO) ? state.getFluidState() : net.minecraft.world.level.material.Fluids.EMPTY.defaultFluidState();
            case "getBlockEntity" -> null;
            case "getHeight" -> 384;
            case "getMinY", "getMinBuildHeight" -> -64;
            case "hashCode" -> System.identityHashCode(proxy);
            case "equals" -> proxy == arguments[0];
            case "toString" -> "MobSnapshot.alone";
            default -> InvocationHandler.invokeDefault(proxy, method, arguments);
        };
        return (BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(), new Class<?>[] { BlockGetter.class }, handler);
    }

    private MobSnapshot() {}
}
