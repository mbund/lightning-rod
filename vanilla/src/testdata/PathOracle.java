// Prints vanilla's paths for mobs_test.zig: runs 1.21.8's WalkNodeEvaluator and PathFinder for a
// cow on random terrain, without a server. The level, region and cow are bare objects with only
// the fields the pathfinder reads. Run with the Mojang mapped 1.21.8 jar and its libraries:
//   java -cp <jar and libraries> PathOracle.java path_palette.txt 1000 paths.txt
import java.lang.reflect.Field;
import java.util.EnumMap;
import java.util.List;
import java.util.Set;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.Mob;
import net.minecraft.world.entity.ai.attributes.AttributeMap;
import net.minecraft.world.entity.ai.attributes.DefaultAttributes;
import net.minecraft.world.entity.animal.Cow;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.PathNavigationRegion;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.dimension.BuiltinDimensionTypes;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.pathfinder.PathFinder;
import net.minecraft.world.level.pathfinder.PathType;
import net.minecraft.world.level.pathfinder.PathTypeCache;
import net.minecraft.world.level.pathfinder.WalkNodeEvaluator;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.VoxelShape;
import sun.misc.Unsafe;

public class PathOracle {
    static Unsafe unsafe;
    static BlockState[] volume;
    static final int SIZE_X = 24, SIZE_Y = 12, SIZE_Z = 24;

    static BlockState at(BlockPos pos) {
        if (pos.getX() < 0 || pos.getY() < 0 || pos.getZ() < 0 || pos.getX() >= SIZE_X || pos.getY() >= SIZE_Y || pos.getZ() >= SIZE_Z) return Blocks.AIR.defaultBlockState();
        return volume[(pos.getY() * SIZE_Z + pos.getZ()) * SIZE_X + pos.getX()];
    }

    public static class Region extends PathNavigationRegion {
        public Region() { super(null, null, null); }
        @Override public BlockState getBlockState(BlockPos pos) { return at(pos); }
        @Override public FluidState getFluidState(BlockPos pos) { return at(pos).getFluidState(); }
        @Override public BlockEntity getBlockEntity(BlockPos pos) { return null; }
        @Override public BlockGetter getChunkForCollisions(int x, int z) { return this; }
        @Override public List<VoxelShape> getEntityCollisions(Entity entity, AABB box) { return List.of(); }
        @Override public WorldBorder getWorldBorder() { return new WorldBorder(); }
        @Override public int getMinY() { return 0; }
        @Override public int getHeight() { return 256; }
    }

    static void set(Class<?> owner, Object target, String name, Object value) throws Exception {
        Field field = owner.getDeclaredField(name);
        field.setAccessible(true);
        field.set(target, value);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    static net.minecraft.network.syncher.SynchedEntityData synchedData(Cow cow) throws Throwable {
        var builder = new net.minecraft.network.syncher.SynchedEntityData.Builder(cow);
        Object[][] base = { {"DATA_SHARED_FLAGS_ID", (byte) 0}, {"DATA_AIR_SUPPLY_ID", 300}, {"DATA_CUSTOM_NAME_VISIBLE", false}, {"DATA_CUSTOM_NAME", java.util.Optional.empty()}, {"DATA_SILENT", false}, {"DATA_NO_GRAVITY", false}, {"DATA_POSE", net.minecraft.world.entity.Pose.STANDING}, {"DATA_TICKS_FROZEN", 0} };
        for (Object[] entry : base) {
            Field field = Entity.class.getDeclaredField((String) entry[0]);
            field.setAccessible(true);
            builder.define((net.minecraft.network.syncher.EntityDataAccessor) field.get(null), entry[1]);
        }
        var lookup = java.lang.invoke.MethodHandles.privateLookupIn(Cow.class, java.lang.invoke.MethodHandles.lookup());
        var define = lookup.findSpecial(net.minecraft.world.entity.AgeableMob.class, "defineSynchedData", java.lang.invoke.MethodType.methodType(void.class, net.minecraft.network.syncher.SynchedEntityData.Builder.class), Cow.class);
        define.invoke(cow, builder);
        Field variant = Cow.class.getDeclaredField("DATA_VARIANT_ID");
        variant.setAccessible(true);
        builder.define((net.minecraft.network.syncher.EntityDataAccessor) variant.get(null), Holder.direct(null));
        return builder.build();
    }

    public static void main(String[] args) throws Throwable {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        var builtin = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
        try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource()))) {
            for (var tags : TagLoader.loadTagsForExistingRegistries(resources, builtin)) tags.apply();
        }
        Field theUnsafe = Unsafe.class.getDeclaredField("theUnsafe");
        theUnsafe.setAccessible(true);
        unsafe = (Unsafe) theUnsafe.get(null);
        var level = (ServerLevel) unsafe.allocateInstance(ServerLevel.class);
        set(Level.class, level, "dimensionTypeRegistration", Holder.direct(new DimensionType(java.util.OptionalLong.empty(), true, false, false, true, 1.0, true, false, 0, 256, 256, net.minecraft.tags.BlockTags.INFINIBURN_OVERWORLD, BuiltinDimensionTypes.OVERWORLD_EFFECTS, 0.0F, java.util.Optional.empty(), new DimensionType.MonsterSettings(false, true, net.minecraft.util.valueproviders.UniformInt.of(0, 7), 0))));
        set(ServerLevel.class, level, "pathTypesByPosCache", new PathTypeCache());
        var palette = new java.util.ArrayList<BlockState>();
        for (var line : java.nio.file.Files.readAllLines(java.nio.file.Path.of(args[0]))) {
            if (line.isBlank()) continue;
            palette.add(net.minecraft.commands.arguments.blocks.BlockStateParser.parseForBlock(BuiltInRegistries.BLOCK, line, false).blockState());
        }
        var out = new StringBuilder();
        for (int seed = 1; seed <= Integer.parseInt(args[1]); seed++) out.append(scenario(seed, palette, level));
        java.nio.file.Files.writeString(java.nio.file.Path.of(args[2]), out.toString());
    }

    static String scenario(int seed, java.util.List<BlockState> palette, ServerLevel level) throws Throwable {
        var random = new java.util.Random(seed);
        set(ServerLevel.class, level, "pathTypesByPosCache", new PathTypeCache());
        volume = new BlockState[SIZE_X * SIZE_Y * SIZE_Z];
        java.util.Arrays.fill(volume, Blocks.AIR.defaultBlockState());
        int[][] heights = new int[SIZE_Z][SIZE_X];
        for (int z = 0; z < SIZE_Z; z++) for (int x = 0; x < SIZE_X; x++) {
            int height = 3 + random.nextInt(3);
            heights[z][x] = height;
            for (int y = 0; y < height; y++) volume[(y * SIZE_Z + z) * SIZE_X + x] = y == height - 1 ? Blocks.GRASS_BLOCK.defaultBlockState() : Blocks.STONE.defaultBlockState();
            for (int y = height; y < height + 2; y++) if (random.nextInt(5) == 0) volume[(y * SIZE_Z + z) * SIZE_X + x] = palette.get(random.nextInt(palette.size()));
        }
        int startX = 6 + random.nextInt(12), startZ = 6 + random.nextInt(12);
        int targetX = random.nextInt(SIZE_X), targetZ = random.nextInt(SIZE_Z);
        boolean baby = random.nextInt(2) == 0;
        var dimensions = baby ? EntityType.COW.getDimensions().scale(0.5F).withEyeHeight(0.665F) : EntityType.COW.getDimensions();
        var cow = (Cow) unsafe.allocateInstance(Cow.class);
        set(Entity.class, cow, "level", level);
        set(Entity.class, cow, "type", EntityType.COW);
        set(Entity.class, cow, "dimensions", dimensions);
        set(LivingEntity.class, cow, "attributes", new AttributeMap(DefaultAttributes.getSupplier(EntityType.COW)));
        var malus = new EnumMap<PathType, Float>(PathType.class);
        malus.put(PathType.DANGER_FIRE, 16.0F);
        malus.put(PathType.DAMAGE_FIRE, -1.0F);
        set(Mob.class, cow, "pathfindingMalus", malus);
        var position = new Vec3(startX + 0.5, heights[startZ][startX], startZ + 0.5);
        set(Entity.class, cow, "position", position);
        set(Entity.class, cow, "blockPosition", BlockPos.containing(position));
        set(Entity.class, cow, "bb", dimensions.makeBoundingBox(position));
        set(Entity.class, cow, "onGround", true);
        set(Entity.class, cow, "passengers", com.google.common.collect.ImmutableList.of());
        set(Entity.class, cow, "entityData", synchedData(cow));
        set(LivingEntity.class, cow, "equipment", new net.minecraft.world.entity.EntityEquipment());
        var evaluator = new WalkNodeEvaluator();
        evaluator.setCanPassDoors(true);
        evaluator.setCanFloat(true);
        var finder = new PathFinder(evaluator, 256);
        var region = (Region) unsafe.allocateInstance(Region.class);
        var path = finder.findPath(region, cow, Set.of(new BlockPos(targetX, heights[targetZ][targetX], targetZ)), 16.0F, 1, 1.0F);
        var line = new StringBuilder();
        line.append(seed).append(path == null ? " none 0\n" : (path.canReach() ? " reached " : " unreached ") + path.getNodeCount() + "\n");
        if (path != null) for (int i = 0; i < path.getNodeCount(); i++) {
            var node = path.getNode(i);
            line.append(node.x).append(' ').append(node.y).append(' ').append(node.z).append(' ').append(node.type.ordinal()).append('\n');
        }
        return line.toString();
    }
}
