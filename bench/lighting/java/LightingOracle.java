import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.function.BiConsumer;
import com.mojang.serialization.Lifecycle;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.MappedRegistry;
import net.minecraft.core.Registry;
import net.minecraft.core.registries.Registries;
import net.minecraft.core.SectionPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeSpecialEffects;
import net.minecraft.world.level.biome.BiomeGenerationSettings;
import net.minecraft.world.level.biome.Biomes;
import net.minecraft.world.level.biome.MobSpawnSettings;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LightChunk;
import net.minecraft.world.level.chunk.LightChunkGetter;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.lighting.ChunkSkyLightSources;
import net.minecraft.world.level.lighting.LevelLightEngine;
import net.minecraft.world.level.lighting.LightEngine;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

public final class LightingOracle {
    private static final int SIDE = 48;
    private static final Direction[] DIRECTIONS = { Direction.WEST, Direction.EAST, Direction.NORTH, Direction.SOUTH, Direction.DOWN, Direction.UP };
    private static final String[] CASES = { "empty", "flat", "roof", "shaft", "water", "leaves", "glass", "tinted_glass", "slabs", "stairs", "emitters", "chunk_boundary", "random", "tall_world", "cave", "overlapping_emitters", "nether_emitters", "lava", "batch_emitters", "batch_cave", "clear_emitters" };
    private record Change(String name, BlockPos[] positions, BlockState[] states) {}
    private static final ThreadMXBean CPU = ManagementFactory.getThreadMXBean();
    private static final int WARMUP = 32;
    private static final int REPEATS = 32;

    public static void main(String[] args) throws Exception {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        if (!CPU.isCurrentThreadCpuTimeSupported()) throw new IllegalStateException("Thread CPU time unavailable");
        if (!CPU.isThreadCpuTimeEnabled()) CPU.setThreadCpuTimeEnabled(true);
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(Path.of(args[0]))))) {
            output.write("LRLIGHT4".getBytes(StandardCharsets.US_ASCII));
            var faces = new ArrayList<VoxelShape>();
            var index = new LinkedHashMap<String, Integer>();
            faces.add(Shapes.empty());
            index.put(Shapes.empty().toAabbs().toString(), 0);
            int[][] stateFaces = new int[Block.BLOCK_STATE_REGISTRY.size()][6];
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                int id = Block.getId(state);
                for (int d = 0; d < 6; d++) {
                    var face = LightEngine.getOcclusionShape(state, DIRECTIONS[d]);
                    var key = face.toAabbs().toString();
                    Integer at = index.get(key);
                    if (at == null) {
                        at = faces.size();
                        faces.add(face);
                        index.put(key, at);
                    }
                    stateFaces[id][d] = at;
                }
            }
            output.writeInt(stateFaces.length);
            output.writeInt(faces.size());
            for (var state : Block.BLOCK_STATE_REGISTRY) {
                output.writeByte(OracleApi.opacity(state));
                output.writeByte(state.getLightEmission());
                for (int face : stateFaces[Block.getId(state)]) output.writeShort(face);
            }
            for (var a : faces) for (var b : faces) output.writeBoolean(Shapes.faceShapeOccludes(a, b));
            output.writeInt(CASES.length);
            for (String scenario : CASES) {
                var world = new World(scenario.equals("tall_world") ? 384 : 64, !scenario.equals("nether_emitters"));
                world.populate(scenario);
                var initial = world.blocks.clone();
                world.light();
                var snapshots = new ArrayList<byte[]>();
                byte[] name = scenario.getBytes(StandardCharsets.UTF_8);
                output.writeInt(name.length);
                output.write(name);
                output.writeInt(SIDE);
                output.writeInt(world.height + 32);
                output.writeInt(SIDE);
                output.writeBoolean(world.skylight);
                for (int y = -16; y < world.height + 16; y++) for (int z = 0; z < SIDE; z++) for (int x = 0; x < SIDE; x++)
                    output.writeShort(Block.getId(world.getBlockState(new BlockPos(x, y, z))));
                snapshots.add(snapshot(world));
                output.write(snapshots.getLast());
                var changes = changes(scenario);
                output.writeInt(changes.size());
                for (var change : changes) {
                    byte[] label = change.name.getBytes(StandardCharsets.UTF_8);
                    output.writeInt(label.length);
                    output.write(label);
                    output.writeInt(change.positions.length);
                    for (int at = 0; at < change.positions.length; at++) {
                        var pos = change.positions[at];
                        output.writeInt(((pos.getY() + 16) * SIDE + pos.getZ()) * SIDE + pos.getX());
                        output.writeShort(Block.getId(change.states[at]));
                    }
                    world.apply(change);
                    snapshots.add(snapshot(world));
                    output.write(snapshots.getLast());
                }
                benchmark(output, world, initial, changes, snapshots);
                System.out.println("Vanilla lighting: " + scenario);
            }
        }
    }

    private static byte[] snapshot(World world) {
        var values = new byte[(world.height + 32) * 256 * 2];
        int at = 0;
        for (var layer : new LightLayer[] { LightLayer.BLOCK, LightLayer.SKY }) {
            var listener = world.engine.getLayerListener(layer);
            for (int y = -16; y < world.height + 16; y++) for (int z = 16; z < 32; z++) for (int x = 16; x < 32; x++)
                values[at++] = (byte) listener.getLightValue(new BlockPos(x, y, z));
        }
        return values;
    }

    private static void benchmark(DataOutputStream output, World template, BlockState[] initial,
                                  ArrayList<Change> changes, ArrayList<byte[]> expected) throws Exception {
        long[][] samples = new long[changes.size() + 1][REPEATS];
        for (int repeat = -WARMUP; repeat < REPEATS; repeat++) {
            var world = new World(template.height, template.skylight);
            System.arraycopy(initial, 0, world.blocks, 0, initial.length);
            world.prepareLight();
            long start = CPU.getCurrentThreadCpuTime();
            world.propagateLight();
            long elapsed = CPU.getCurrentThreadCpuTime() - start;
            if (repeat >= 0) samples[0][repeat] = elapsed;
            if (!java.util.Arrays.equals(snapshot(world), expected.getFirst())) throw new IllegalStateException("Unstable initial lighting");
            for (int step = 0; step < changes.size(); step++) {
                start = CPU.getCurrentThreadCpuTime();
                world.apply(changes.get(step));
                elapsed = CPU.getCurrentThreadCpuTime() - start;
                if (repeat >= 0) samples[step + 1][repeat] = elapsed;
                if (!java.util.Arrays.equals(snapshot(world), expected.get(step + 1))) throw new IllegalStateException("Unstable lighting: " + changes.get(step).name);
            }
        }
        for (var sample : samples) {
            java.util.Arrays.sort(sample);
            output.writeLong(sample[REPEATS / 2]);
            output.writeLong(sample[REPEATS * 95 / 100]);
        }
    }

    private static ArrayList<Change> changes(String scenario) {
        var result = new ArrayList<Change>();
        var opening = new BlockPos(24, 32, 24);
        if (scenario.equals("cave")) {
            result.add(single("open_cave", opening, Blocks.AIR));
            result.add(single("seal_cave", opening, Blocks.STONE));
            result.add(single("reopen_cave", opening, Blocks.AIR));
            result.add(single("slab_over_opening", opening, Blocks.STONE_SLAB));
            result.add(single("remove_slab", opening, Blocks.AIR));
        }
        if (scenario.equals("overlapping_emitters")) {
            var torch = new BlockPos(22, 12, 24);
            var glow = new BlockPos(26, 12, 24);
            var redstone = new BlockPos(24, 12, 28);
            result.add(single("unchanged_air", torch, Blocks.AIR));
            result.add(single("add_torch", torch, Blocks.TORCH));
            result.add(single("add_glowstone", glow, Blocks.GLOWSTONE));
            result.add(single("add_redstone_torch", redstone, Blocks.REDSTONE_TORCH));
            var shell = new BlockPos[6];
            var solid = new BlockState[6];
            var air = new BlockState[6];
            var glass = new BlockState[6];
            for (int d = 0; d < 6; d++) {
                shell[d] = glow.relative(DIRECTIONS[d]);
                solid[d] = Blocks.STONE.defaultBlockState();
                air[d] = Blocks.AIR.defaultBlockState();
                glass[d] = Blocks.GLASS.defaultBlockState();
            }
            result.add(new Change("enclose_glowstone", shell, solid));
            result.add(single("remove_torch", torch, Blocks.AIR));
            result.add(new Change("glass_around_glowstone", shell, glass));
            result.add(new Change("expose_glowstone", shell, air));
            result.add(single("remove_glowstone", glow, Blocks.AIR));
            result.add(single("remove_redstone", redstone, Blocks.AIR));
        }
        if (scenario.equals("batch_emitters") || scenario.equals("batch_cave") || scenario.equals("clear_emitters")) {
            boolean cave = scenario.equals("batch_cave");
            int y = cave || scenario.equals("clear_emitters") ? 32 : 12;
            var positions = new BlockPos[64];
            var placed = new BlockState[64];
            var removed = new BlockState[64];
            for (int i = 0; i < positions.length; i++) {
                positions[i] = new BlockPos(10 + (i % 8) * 4, y, 10 + (i / 8) * 4);
                placed[i] = (cave ? Blocks.AIR : Blocks.TORCH).defaultBlockState();
                removed[i] = (cave ? Blocks.STONE : Blocks.AIR).defaultBlockState();
            }
            if (scenario.equals("clear_emitters")) {
                result.add(single("add_one", opening, Blocks.TORCH));
                result.add(single("remove_one", opening, Blocks.AIR));
                for (int count : new int[] { 4, 16 }) {
                    var subset = java.util.Arrays.copyOf(positions, count);
                    result.add(new Change("add_" + count, subset, java.util.Arrays.copyOf(placed, count)));
                    result.add(new Change("remove_" + count, subset, java.util.Arrays.copyOf(removed, count)));
                }
            }
            result.add(new Change(cave ? "open_64" : "add_64", positions, placed));
            if (scenario.equals("batch_emitters")) {
                result.add(single("remove_one", positions[27], Blocks.AIR));
                result.add(single("replace_one", positions[27], Blocks.TORCH));
            }
            result.add(new Change(cave ? "seal_64" : "remove_64", positions, removed));
            if (scenario.equals("batch_emitters")) {
                var unordered = new BlockPos[64];
                for (int i = 0; i < unordered.length; i++) unordered[i] = positions[(i * 37) % 64];
                result.add(new Change("add_shuffled_64", unordered, placed));
                result.add(new Change("remove_shuffled_64", unordered, removed));
                var repeated = new BlockPos[256];
                var toggled = new BlockState[256];
                var cancelled = new BlockState[256];
                for (int i = 0; i < repeated.length; i++) {
                    repeated[i] = positions[i / 8];
                    toggled[i] = (i % 2 == 0 || i % 8 == 7 ? Blocks.TORCH : Blocks.AIR).defaultBlockState();
                    cancelled[i] = (i % 2 == 0 ? Blocks.TORCH : Blocks.AIR).defaultBlockState();
                }
                result.add(new Change("repeat_32", repeated, toggled));
                result.add(new Change("clear_32", java.util.Arrays.copyOf(positions, 32), java.util.Arrays.copyOf(removed, 32)));
                result.add(new Change("cancel_32", repeated, cancelled));
                var shuffled = new BlockPos[256];
                var shuffledPlaced = new BlockState[256];
                var shuffledCancelled = new BlockState[256];
                for (int i = 0; i < shuffled.length; i++) {
                    shuffled[i] = positions[(i * 13) % 32];
                    int round = i / 32;
                    shuffledPlaced[i] = (round % 2 == 0 || round == 7 ? Blocks.TORCH : Blocks.AIR).defaultBlockState();
                    shuffledCancelled[i] = (round % 2 == 0 ? Blocks.TORCH : Blocks.AIR).defaultBlockState();
                }
                result.add(new Change("repeat_shuffled_32", shuffled, shuffledPlaced));
                result.add(new Change("clear_shuffled_32", java.util.Arrays.copyOf(positions, 32), java.util.Arrays.copyOf(removed, 32)));
                result.add(new Change("cancel_shuffled_32", shuffled, shuffledCancelled));
            }
        }
        return result;
    }

    private static Change single(String name, BlockPos position, Block block) {
        return new Change(name, new BlockPos[] { position }, new BlockState[] { block.defaultBlockState() });
    }

    private static final class World implements BlockGetter, LightChunkGetter {
        private static final Registry<Biome> BIOMES = biomes();

        private static Registry<Biome> biomes() {
            var registry = new MappedRegistry<Biome>(Registries.BIOME, Lifecycle.stable());
            var biome = new Biome.BiomeBuilder().hasPrecipitation(false).temperature(0.5f).downfall(0)
                .specialEffects(OracleApi.effects())
                .mobSpawnSettings(MobSpawnSettings.EMPTY).generationSettings(BiomeGenerationSettings.EMPTY).build();
            Registry.register(registry, Biomes.PLAINS, biome);
            return registry.freeze();
        }

        final int height;
        final boolean skylight;
        final BlockState[] blocks;
        final Column[] columns = new Column[9];
        final boolean[] changed = new boolean[256];
        LevelLightEngine engine;

        World(int height, boolean skylight) {
            this.height = height;
            this.skylight = skylight;
            blocks = new BlockState[SIDE * SIDE * height];
            java.util.Arrays.fill(blocks, Blocks.AIR.defaultBlockState());
            for (int z = 0; z < 3; z++) for (int x = 0; x < 3; x++) columns[z * 3 + x] = new Column(this, x, z);
        }

        @Override public int getHeight() { return height; }
        @Override public int getMinY() { return 0; }
        @Override public BlockEntity getBlockEntity(BlockPos pos) { return null; }
        @Override public FluidState getFluidState(BlockPos pos) { return getBlockState(pos).getFluidState(); }
        @Override public BlockState getBlockState(BlockPos pos) {
            int x = pos.getX(), y = pos.getY(), z = pos.getZ();
            if (y < 0 || y >= height) return Blocks.AIR.defaultBlockState();
            if (x < 0 || x >= SIDE || z < 0 || z >= SIDE) return Blocks.BEDROCK.defaultBlockState();
            return blocks[(y * SIDE + z) * SIDE + x];
        }
        @Override public LightChunk getChunkForLighting(int x, int z) { return x >= 0 && x < 3 && z >= 0 && z < 3 ? columns[z * 3 + x] : null; }
        @Override public BlockGetter getLevel() { return this; }

        void populate(String scenario) {
            long random = 20261027;
            for (int y = 0; y < height; y++) for (int z = 0; z < SIDE; z++) for (int x = 0; x < SIDE; x++) {
                BlockState state = Blocks.AIR.defaultBlockState();
                if (!scenario.equals("empty") && !scenario.equals("clear_emitters") && y < 4) state = Blocks.STONE.defaultBlockState();
                boolean roof = y == 32 && x >= 8 && x < 40 && z >= 8 && z < 40;
                if (roof && (scenario.equals("roof") || scenario.equals("shaft"))) state = Blocks.STONE.defaultBlockState();
                if (scenario.equals("shaft") && y == 32 && x == 24 && z == 24) state = Blocks.AIR.defaultBlockState();
                if ((scenario.equals("cave") || scenario.equals("batch_cave")) && y == 32) state = Blocks.STONE.defaultBlockState();
                if (y >= 4 && y < 20) {
                    if (scenario.equals("water")) state = Blocks.WATER.defaultBlockState();
                    if (scenario.equals("lava")) state = Blocks.LAVA.defaultBlockState();
                    if (scenario.equals("leaves")) state = Blocks.OAK_LEAVES.defaultBlockState();
                }
                if (roof) {
                    if (scenario.equals("glass")) state = Blocks.GLASS.defaultBlockState();
                    if (scenario.equals("tinted_glass")) state = Blocks.TINTED_GLASS.defaultBlockState();
                    if (scenario.equals("slabs")) state = Blocks.STONE_SLAB.defaultBlockState();
                    if (scenario.equals("stairs")) state = Blocks.OAK_STAIRS.defaultBlockState();
                }
                if ((scenario.equals("emitters") || scenario.equals("chunk_boundary") || scenario.equals("nether_emitters")) && y == 12 && z % 13 == 0 && x % 15 == 0)
                    state = (x % 2 == 0 ? Blocks.TORCH : Blocks.GLOWSTONE).defaultBlockState();
                if (scenario.equals("random") && y >= 4 && y < 36) {
                    random ^= random << 13;
                    random ^= random >>> 7;
                    random ^= random << 17;
                    int n = (int) Long.remainderUnsigned(random, 128);
                    if (n == 0) state = Blocks.GLOWSTONE.defaultBlockState();
                    if (n == 1) state = Blocks.OAK_STAIRS.defaultBlockState();
                    if (n == 2) state = Blocks.STONE_SLAB.defaultBlockState();
                    if (n >= 3 && n < 20) state = Blocks.STONE.defaultBlockState();
                    if (n >= 20 && n < 24) state = Blocks.WATER.defaultBlockState();
                }
                if (scenario.equals("tall_world") && y < 260 + ((x ^ z) & 15)) state = Blocks.STONE.defaultBlockState();
                blocks[(y * SIDE + z) * SIDE + x] = state;
            }
            if (scenario.equals("chunk_boundary")) {
                blocks[(12 * SIDE + 24) * SIDE + 15] = Blocks.GLOWSTONE.defaultBlockState();
                blocks[(12 * SIDE + 24) * SIDE + 32] = Blocks.GLOWSTONE.defaultBlockState();
            }
        }

        void apply(Change change) {
            if (change.positions.length > changed.length) throw new IllegalArgumentException("Edit batch too large");
            boolean pending = false;
            for (int at = 0; at < change.positions.length; at++) {
                var pos = change.positions[at];
                int index = (pos.getY() * SIDE + pos.getZ()) * SIDE + pos.getX();
                changed[at] = LightEngine.hasDifferentLightProperties(blocks[index], change.states[at]);
                pending |= changed[at];
                blocks[index] = change.states[at];
                var column = columns[(pos.getZ() / 16) * 3 + pos.getX() / 16];
                var section = column.sections[pos.getY() / 16];
                boolean wasEmpty = section.hasOnlyAir();
                section.setBlockState(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, change.states[at], false);
                if (wasEmpty != section.hasOnlyAir()) {
                    engine.updateSectionStatus(SectionPos.of(pos), section.hasOnlyAir());
                    pending = true;
                }
            }
            if (!pending) return;
            for (int at = 0; at < change.positions.length; at++) {
                if (!changed[at]) continue;
                var pos = change.positions[at];
                var column = columns[(pos.getZ() / 16) * 3 + pos.getX() / 16];
                column.sky.update(column.view, pos.getX() & 15, pos.getY(), pos.getZ() & 15);
                engine.checkBlock(pos);
            }
            engine.runLightUpdates();
            while (engine.hasLightWork()) engine.runLightUpdates();
        }

        void light() {
            prepareLight();
            propagateLight();
        }

        void prepareLight() {
            for (var column : columns) {
                column.prepareSections();
                for (int z = 0; z < 16; z++) for (int x = 0; x < 16; x++)
                    for (int y = height - 1; y >= 0; y--) column.sky.update(column.view, x, y, z);
            }
            engine = new LevelLightEngine(this, true, skylight);
            for (var column : columns) for (int y = 0; y < height / 16; y++) engine.updateSectionStatus(SectionPos.of(column.x, y, column.z), column.sections[y].hasOnlyAir());
            engine.runLightUpdates();
        }

        void propagateLight() {
            for (var column : columns) {
                var pos = new ChunkPos(column.x, column.z);
                engine.setLightEnabled(pos, true);
                engine.propagateLightSources(pos);
            }
            engine.runLightUpdates();
            while (engine.hasLightWork()) engine.runLightUpdates();
            if (engine.getLayerListener(LightLayer.SKY).getLightValue(new BlockPos(24, height + 1, 24)) != (skylight ? 15 : 0))
                throw new IllegalStateException("Vanilla skylight was not published");
        }
    }

    private record ColumnView(Column column) implements BlockGetter {
        @Override public int getHeight() { return column.getHeight(); }
        @Override public int getMinY() { return column.getMinY(); }
        @Override public BlockEntity getBlockEntity(BlockPos pos) { return null; }
        @Override public FluidState getFluidState(BlockPos pos) { return getBlockState(pos).getFluidState(); }
        @Override public BlockState getBlockState(BlockPos pos) { return column.getBlockState(pos.offset(column.x * 16, 0, column.z * 16)); }
    }

    private static final class Column implements LightChunk {
        final World world;
        final int x, z;
        final ChunkSkyLightSources sky;
        final ColumnView view;
        LevelChunkSection[] sections;
        Column(World world, int x, int z) { this.world = world; this.x = x; this.z = z; sky = new ChunkSkyLightSources(world); view = new ColumnView(this); }
        @Override public int getHeight() { return world.getHeight(); }
        @Override public int getMinY() { return world.getMinY(); }
        @Override public BlockEntity getBlockEntity(BlockPos pos) { return null; }
        @Override public FluidState getFluidState(BlockPos pos) { return world.getFluidState(pos); }
        void prepareSections() {
            sections = new LevelChunkSection[world.height / 16];
            for (int section = 0; section < sections.length; section++) {
                sections[section] = OracleApi.section(World.BIOMES);
                for (int y = 0; y < 16; y++) for (int z = 0; z < 16; z++) for (int x = 0; x < 16; x++) {
                    var state = world.blocks[((section * 16 + y) * SIDE + this.z * 16 + z) * SIDE + this.x * 16 + x];
                    sections[section].setBlockState(x, y, z, state, false);
                }
            }
        }
        @Override public BlockState getBlockState(BlockPos pos) {
            int y = pos.getY();
            return y < 0 || y >= world.height ? Blocks.AIR.defaultBlockState()
                : sections[y / 16].getBlockState(pos.getX() & 15, y & 15, pos.getZ() & 15);
        }
        @Override public ChunkSkyLightSources getSkyLightSources() { return sky; }
        @Override public void findBlockLightSources(BiConsumer<BlockPos, BlockState> consumer) {
            var position = new BlockPos.MutableBlockPos();
            for (int section = 0; section < sections.length; section++) {
                var states = sections[section];
                if (!states.maybeHas(state -> state.getLightEmission() != 0)) continue;
                for (int y = 0; y < 16; y++) for (int z = 0; z < 16; z++) for (int x = 0; x < 16; x++) {
                    var state = states.getBlockState(x, y, z);
                    if (state.getLightEmission() != 0)
                        consumer.accept(position.set(this.x * 16 + x, section * 16 + y, this.z * 16 + z), state);
                }
            }
        }
    }
}
