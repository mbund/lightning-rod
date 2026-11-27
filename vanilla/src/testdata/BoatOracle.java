// Prints vanilla's boats for boats_test.zig: runs 1.21.8's AbstractBoat.tick for an oak boat no
// player steers, on random water, ice, slime and currents, without a server. The level and boat
// are bare objects with only the fields the tick reads. Run with the Mojang mapped 1.21.8 jar and
// its libraries:
//   java -cp <jar and libraries> BoatOracle.java boat_palette.txt 150 boats.txt
// Each scenario is a line of its seed, then a line a tick of a hash of the boat's state after it.
// With `full` after the output, each tick's line is the state itself, for finding where a port
// strays. With `clips`, each scenario lists what twenty rays through its terrain hit instead.
import java.lang.reflect.Field;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.function.Predicate;
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
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.tags.TagLoader;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.InsideBlockEffectApplier;
import net.minecraft.world.entity.InterpolationHandler;
import net.minecraft.world.entity.vehicle.AbstractBoat;
import net.minecraft.world.entity.vehicle.Boat;
import net.minecraft.world.entity.vehicle.VehicleEntity;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.dimension.BuiltinDimensionTypes;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.entity.EntityInLevelCallback;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import sun.misc.Unsafe;

public class BoatOracle {
    static Unsafe unsafe;
    static BlockState[] volume;
    static final int SIZE_X = 20, SIZE_Y = 10, SIZE_Z = 20, TICKS = 100;
    static final WorldBorder border = new WorldBorder();
    static net.minecraft.server.ServerScoreboard scoreboard;

    static BlockState at(BlockPos pos) {
        if (pos.getX() < 0 || pos.getY() < 0 || pos.getZ() < 0 || pos.getX() >= SIZE_X || pos.getY() >= SIZE_Y || pos.getZ() >= SIZE_Z) return Blocks.AIR.defaultBlockState();
        return volume[(pos.getY() * SIZE_Z + pos.getZ()) * SIZE_X + pos.getX()];
    }

    static void put(int x, int y, int z, BlockState state) {
        volume[(y * SIZE_Z + z) * SIZE_X + x] = state;
    }

    /// The level a boat reads: the volume, no entities, sounds and events going nowhere.
    public static class FakeLevel extends ServerLevel {
        public FakeLevel() { super(null, null, null, null, null, null, null, false, 0L, null, false, null); }
        @Override public BlockState getBlockState(BlockPos pos) { return at(pos); }
        @Override public FluidState getFluidState(BlockPos pos) { return at(pos).getFluidState(); }
        @Override public BlockGetter getChunkForCollisions(int x, int z) { return region; }
        @Override public List<Entity> getEntities(Entity except, AABB box, Predicate<? super Entity> predicate) { return List.of(); }
        @Override public WorldBorder getWorldBorder() { return border; }
        @Override public void gameEvent(Holder<GameEvent> event, Vec3 at, GameEvent.Context context) {}
        @Override public void playSeededSound(Entity player, double x, double y, double z, Holder<SoundEvent> sound, SoundSource source, float volume, float pitch, long seed) {}
        @Override public void playSeededSound(Entity player, Entity entity, Holder<SoundEvent> sound, SoundSource source, float volume, float pitch, long seed) {}
        @Override public boolean isRainingAt(BlockPos pos) { return false; }
        @Override public boolean hasChunk(int x, int z) { return true; }
        // A boat breaks lily pads, whose drops this level has nowhere to put.
        @Override public boolean destroyBlock(BlockPos pos, boolean drop, Entity breaker, int depth) {
            if (at(pos).isAir()) return false;
            put(pos.getX(), pos.getY(), pos.getZ(), at(pos).getFluidState().createLegacyBlock());
            return true;
        }
        @Override public net.minecraft.server.ServerScoreboard getScoreboard() { return scoreboard; }
    }

    static final BlockGetter region = new BlockGetter() {
        @Override public BlockEntity getBlockEntity(BlockPos pos) { return null; }
        @Override public BlockState getBlockState(BlockPos pos) { return at(pos); }
        @Override public FluidState getFluidState(BlockPos pos) { return at(pos).getFluidState(); }
        @Override public int getHeight() { return 256; }
        @Override public int getMinY() { return 0; }
    };

    static void set(Class<?> owner, Object target, String name, Object value) throws Exception {
        Field field = owner.getDeclaredField(name);
        field.setAccessible(true);
        if (java.lang.reflect.Modifier.isFinal(field.getModifiers())) {
            unsafe.putObject(target, unsafe.objectFieldOffset(field), value);
        } else field.set(target, value);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    static net.minecraft.network.syncher.SynchedEntityData synchedData(Boat boat) throws Throwable {
        var builder = new net.minecraft.network.syncher.SynchedEntityData.Builder(boat);
        Object[][] base = { {Entity.class, "DATA_SHARED_FLAGS_ID", (byte) 0}, {Entity.class, "DATA_AIR_SUPPLY_ID", 300}, {Entity.class, "DATA_CUSTOM_NAME_VISIBLE", false}, {Entity.class, "DATA_CUSTOM_NAME", java.util.Optional.empty()}, {Entity.class, "DATA_SILENT", false}, {Entity.class, "DATA_NO_GRAVITY", false}, {Entity.class, "DATA_POSE", net.minecraft.world.entity.Pose.STANDING}, {Entity.class, "DATA_TICKS_FROZEN", 0},
            {VehicleEntity.class, "DATA_ID_HURT", 0}, {VehicleEntity.class, "DATA_ID_HURTDIR", 1}, {VehicleEntity.class, "DATA_ID_DAMAGE", 0.0F},
            {AbstractBoat.class, "DATA_ID_PADDLE_LEFT", false}, {AbstractBoat.class, "DATA_ID_PADDLE_RIGHT", false}, {AbstractBoat.class, "DATA_ID_BUBBLE_TIME", 0} };
        for (Object[] entry : base) {
            Field field = ((Class<?>) entry[0]).getDeclaredField((String) entry[1]);
            field.setAccessible(true);
            builder.define((net.minecraft.network.syncher.EntityDataAccessor) field.get(null), entry[2]);
        }
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
        // A server scoreboard with an empty scoreboard's maps, which team lookups read.
        scoreboard = (net.minecraft.server.ServerScoreboard) unsafe.allocateInstance(net.minecraft.server.ServerScoreboard.class);
        var empty = new net.minecraft.world.scores.Scoreboard();
        for (Field field : net.minecraft.world.scores.Scoreboard.class.getDeclaredFields()) {
            if (java.lang.reflect.Modifier.isStatic(field.getModifiers())) continue;
            field.setAccessible(true);
            unsafe.putObject(scoreboard, unsafe.objectFieldOffset(field), field.get(empty));
        }
        var level = (FakeLevel) unsafe.allocateInstance(FakeLevel.class);
        set(Level.class, level, "threadSafeRandom", RandomSource.createThreadSafe());
        set(Level.class, level, "random", RandomSource.create(0));
        set(Level.class, level, "dimensionTypeRegistration", Holder.direct(new DimensionType(java.util.OptionalLong.empty(), true, false, false, true, 1.0, true, false, 0, 256, 256, net.minecraft.tags.BlockTags.INFINIBURN_OVERWORLD, BuiltinDimensionTypes.OVERWORLD_EFFECTS, 0.0F, java.util.Optional.empty(), new DimensionType.MonsterSettings(false, true, net.minecraft.util.valueproviders.UniformInt.of(0, 7), 0))));
        var palette = new ArrayList<BlockState>();
        for (var line : java.nio.file.Files.readAllLines(java.nio.file.Path.of(args[0]))) {
            if (line.isBlank()) continue;
            palette.add(net.minecraft.commands.arguments.blocks.BlockStateParser.parseForBlock(BuiltInRegistries.BLOCK, line, false).blockState());
        }
        boolean full = args.length > 3 && args[3].equals("full");
        boolean clips = args.length > 3 && args[3].equals("clips");
        int first = args.length > 4 ? Integer.parseInt(args[4]) : 1;
        var out = new StringBuilder();
        for (int seed = first; seed < first + Integer.parseInt(args[1]); seed++) out.append(clips ? clips(seed, palette, level) : scenario(seed, palette, level, full));
        java.nio.file.Files.writeString(java.nio.file.Path.of(args[2]), out.toString());
    }

    /// The scenario's terrain: stone under a sea up to three deep, or none, and 48 features from
    /// the palette: columns raised from the floor, blocks on the water and bubble columns.
    static void terrain(java.util.Random random, List<BlockState> palette) {
        volume = new BlockState[SIZE_X * SIZE_Y * SIZE_Z];
        java.util.Arrays.fill(volume, Blocks.AIR.defaultBlockState());
        int sea = random.nextInt(4);
        for (int z = 0; z < SIZE_Z; z++) for (int x = 0; x < SIZE_X; x++) {
            put(x, 0, z, Blocks.STONE.defaultBlockState());
            for (int y = 1; y <= sea; y++) put(x, y, z, Blocks.WATER.defaultBlockState());
        }
        for (int i = 0; i < 48; i++) {
            int x = random.nextInt(SIZE_X), z = random.nextInt(SIZE_Z);
            int kind = random.nextInt(palette.size() + 2);
            if (kind == palette.size()) {
                // A bubble column through the sea, up from soul sand or down to magma.
                if (sea == 0) continue;
                boolean drag = random.nextInt(2) == 0;
                put(x, 0, z, drag ? Blocks.MAGMA_BLOCK.defaultBlockState() : Blocks.SOUL_SAND.defaultBlockState());
                for (int y = 1; y <= sea; y++) put(x, y, z, Blocks.BUBBLE_COLUMN.defaultBlockState().setValue(net.minecraft.world.level.block.BubbleColumnBlock.DRAG_DOWN, drag));
            } else if (kind == palette.size() + 1) {
                // Flowing water on the sea, which pushes what floats by it.
                int amount = 1 + random.nextInt(7);
                put(x, sea + 1, z, Blocks.WATER.defaultBlockState().setValue(net.minecraft.world.level.block.LiquidBlock.LEVEL, 8 - amount));
            } else {
                BlockState state = palette.get(kind);
                if (state.is(Blocks.LILY_PAD)) {
                    if (sea > 0) put(x, sea + 1, z, state);
                    continue;
                }
                int top = 1 + random.nextInt(sea + 2);
                for (int y = 1; y <= top; y++) put(x, y, z, state);
            }
        }
    }

    static String scenario(int seed, List<BlockState> palette, FakeLevel level, boolean full) throws Throwable {
        var random = new java.util.Random(seed);
        terrain(random, palette);
        double x = 3 + random.nextInt(14000) / 1000.0;
        double y = 1 + random.nextInt(6000) / 1000.0;
        double z = 3 + random.nextInt(14000) / 1000.0;
        var velocity = new Vec3((random.nextInt(2001) - 1000) / 2000.0, (random.nextInt(1001) - 500) / 1000.0, (random.nextInt(2001) - 1000) / 2000.0);
        var boat = (Boat) unsafe.allocateInstance(Boat.class);
        var dimensions = EntityType.OAK_BOAT.getDimensions();
        set(Entity.class, boat, "level", level);
        set(Entity.class, boat, "type", EntityType.OAK_BOAT);
        set(Entity.class, boat, "dimensions", dimensions);
        set(Entity.class, boat, "eyeHeight", dimensions.eyeHeight());
        set(Entity.class, boat, "random", RandomSource.create(seed));
        set(Entity.class, boat, "passengers", com.google.common.collect.ImmutableList.of());
        set(Entity.class, boat, "entityData", synchedData(boat));
        set(Entity.class, boat, "levelCallback", EntityInLevelCallback.NULL);
        set(Entity.class, boat, "deltaMovement", Vec3.ZERO);
        set(Entity.class, boat, "stuckSpeedMultiplier", Vec3.ZERO);
        set(Entity.class, boat, "position", Vec3.ZERO);
        set(Entity.class, boat, "blockPosition", BlockPos.ZERO);
        set(Entity.class, boat, "chunkPosition", net.minecraft.world.level.ChunkPos.ZERO);
        set(Entity.class, boat, "fluidHeight", new it.unimi.dsi.fastutil.objects.Object2DoubleArrayMap<>(2));
        set(Entity.class, boat, "fluidOnEyes", new HashSet<>());
        set(Entity.class, boat, "movementThisTick", new ArrayDeque<>());
        set(Entity.class, boat, "finalMovementsThisTick", new ArrayList<>());
        set(Entity.class, boat, "visitedBlocks", new it.unimi.dsi.fastutil.longs.LongOpenHashSet());
        set(Entity.class, boat, "insideEffectCollector", new InsideBlockEffectApplier.StepBasedCollector());
        set(Entity.class, boat, "mainSupportingBlockPos", java.util.Optional.empty());
        set(Entity.class, boat, "tags", new HashSet<>());
        set(Entity.class, boat, "firstTick", true);
        set(Entity.class, boat, "nextStep", 1.0F);
        set(Entity.class, boat, "bb", dimensions.makeBoundingBox(0, 0, 0));
        set(AbstractBoat.class, boat, "paddlePositions", new float[2]);
        set(AbstractBoat.class, boat, "interpolation", new InterpolationHandler(boat, 3));
        boat.setInitialPos(x, y, z);
        // Placed where it is clear, as BoatItem places one: a body inside a block's shape collides
        // with the shape's voxel grid, which bodies here do not.
        while (!level.noCollision(boat, boat.getBoundingBox())) {
            y += 1;
            boat.setInitialPos(x, y, z);
        }
        boat.setDeltaMovement(velocity);
        var line = new StringBuilder();
        line.append("seed ").append(seed).append('\n');
        for (int tick = 0; tick < TICKS; tick++) {
            boat.setOldPosAndRot();
            boat.tick();
            line.append(state(boat, full)).append('\n');
            if (boat.isRemoved()) break;
        }
        return line.toString();
    }

    /// Level.clip through outlines and any fluid, as BoatItem.use traces, for twenty rays across
    /// the scenario's terrain: what each hit, or that it missed.
    static String clips(int seed, List<BlockState> palette, FakeLevel level) {
        terrain(new java.util.Random(seed), palette);
        var random = new java.util.Random(seed ^ 0x636c6970);
        var line = new StringBuilder();
        line.append("seed ").append(seed).append('\n');
        for (int ray = 0; ray < 20; ray++) {
            var from = new Vec3(random.nextInt(20000) / 1000.0, 1 + random.nextInt(9000) / 1000.0, random.nextInt(20000) / 1000.0);
            var to = new Vec3(random.nextInt(20000) / 1000.0, random.nextInt(9000) / 1000.0, random.nextInt(20000) / 1000.0);
            var hit = level.clip(new net.minecraft.world.level.ClipContext(from, to, net.minecraft.world.level.ClipContext.Block.OUTLINE, net.minecraft.world.level.ClipContext.Fluid.ANY, net.minecraft.world.phys.shapes.CollisionContext.empty()));
            if (hit.getType() == net.minecraft.world.phys.HitResult.Type.MISS) { line.append("miss\n"); continue; }
            var at = hit.getLocation();
            line.append(Long.toHexString(Double.doubleToRawLongBits(at.x))).append(' ').append(Long.toHexString(Double.doubleToRawLongBits(at.y))).append(' ').append(Long.toHexString(Double.doubleToRawLongBits(at.z))).append(' ');
            line.append(hit.getBlockPos().getX()).append(' ').append(hit.getBlockPos().getY()).append(' ').append(hit.getBlockPos().getZ()).append(' ').append(hit.getDirection().ordinal()).append(' ').append(hit.isInside() ? 1 : 0).append('\n');
        }
        return line.toString();
    }

    static String state(Boat boat, boolean full) throws Exception {
        Field status = AbstractBoat.class.getDeclaredField("status");
        status.setAccessible(true);
        var held = status.get(boat);
        int ordinal = held == null ? -1 : ((Enum<?>) held).ordinal();
        long[] bits = { Double.doubleToRawLongBits(boat.getX()), Double.doubleToRawLongBits(boat.getY()), Double.doubleToRawLongBits(boat.getZ()), Double.doubleToRawLongBits(boat.getDeltaMovement().x), Double.doubleToRawLongBits(boat.getDeltaMovement().y), Double.doubleToRawLongBits(boat.getDeltaMovement().z) };
        if (full) {
            var text = new StringBuilder();
            for (long value : bits) text.append(Long.toHexString(value)).append(' ');
            return text.append(ordinal).append(' ').append(boat.onGround() ? 1 : 0).append(' ').append(boat.fallDistance).toString();
        }
        // FNV-1a over the bits, the status and whether it is on the ground.
        long hash = 0xcbf29ce484222325L;
        for (long value : bits) for (int at = 0; at < 8; at++) {
            hash ^= (value >>> (at * 8)) & 0xff;
            hash *= 0x100000001b3L;
        }
        hash ^= ordinal & 0xff;
        hash *= 0x100000001b3L;
        hash ^= boat.onGround() ? 1 : 0;
        hash *= 0x100000001b3L;
        return Long.toHexString(hash);
    }
}
