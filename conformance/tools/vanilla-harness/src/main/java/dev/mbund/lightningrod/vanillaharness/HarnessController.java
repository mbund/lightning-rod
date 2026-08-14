package dev.mbund.lightningrod.vanillaharness;

import com.mojang.authlib.GameProfile;
import com.mojang.serialization.JsonOps;
import dev.mbund.lightningrod.vanillaharness.mixin.ItemEntityAccessor;
import dev.mbund.lightningrod.vanillaharness.mixin.ServerPlayNetworkHandlerAccessor;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import net.minecraft.block.Block;
import net.minecraft.block.BlockState;
import net.minecraft.block.LeavesBlock;
import net.minecraft.entity.player.PlayerInventory;
import net.minecraft.entity.passive.PassiveEntity;
import net.minecraft.entity.Entity;
import net.minecraft.entity.EntityType;
import net.minecraft.entity.LivingEntity;
import net.minecraft.entity.SpawnReason;
import net.minecraft.entity.ItemEntity;
import net.minecraft.item.Item;
import net.minecraft.item.ItemStack;
import net.minecraft.network.RegistryByteBuf;
import net.minecraft.network.DisconnectionInfo;
import net.minecraft.network.listener.ClientPlayPacketListener;
import net.minecraft.network.listener.ServerPlayPacketListener;
import net.minecraft.network.packet.BundlePacket;
import net.minecraft.network.packet.Packet;
import net.minecraft.network.packet.c2s.play.AcknowledgeChunksC2SPacket;
import net.minecraft.network.packet.c2s.play.PlayerLoadedC2SPacket;
import net.minecraft.network.packet.s2c.play.ChunkSentS2CPacket;
import net.minecraft.network.packet.s2c.play.PlayerPositionLookS2CPacket;
import net.minecraft.network.packet.c2s.common.SyncedClientOptions;
import net.minecraft.network.state.NetworkState;
import net.minecraft.network.state.PlayStateFactories;
import net.minecraft.registry.Registries;
import net.minecraft.registry.Registry;
import net.minecraft.registry.RegistryKeys;
import net.minecraft.registry.entry.RegistryEntry;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.network.ConnectedClientData;
import net.minecraft.server.network.ServerPlayerEntity;
import net.minecraft.server.world.ServerWorld;
import net.minecraft.state.property.Property;
import net.minecraft.util.Identifier;
import net.minecraft.util.math.BlockPos;
import net.minecraft.text.Text;
import net.minecraft.world.GameRules;
import net.minecraft.world.GameMode;
import net.minecraft.world.biome.Biome;
import net.minecraft.world.chunk.Chunk;
import net.minecraft.world.chunk.ChunkStatus;
import net.minecraft.world.gen.chunk.ChunkGenerator;
import net.minecraft.world.gen.feature.PlacedFeature;
import net.minecraft.world.gen.feature.ConfiguredFeature;
import net.minecraft.world.gen.feature.util.PlacedFeatureIndexer;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.Channels;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CountDownLatch;

/**
 * Private process bridge for the Vanilla adapter. Canonical sessions and
 * matching remain entirely in Zig; this class exposes only Vanilla's tick,
 * packet codec, fixture, and connection boundaries.
 */
public final class HarnessController implements AutoCloseable {
    private static final int RESTORE = 1;
    private static final int STAGE = 2;
    private static final int STEP = 3;
    private static final int SHUTDOWN = 4;
    private static final int CONTROL = 5;
    private static final int SNAPSHOT_CHUNK = 6;
    private static final int SNAPSHOT_NOISE_CHUNK = 7;
    private static final int SNAPSHOT_SURFACE_CHUNK = 8;
    private static final int SNAPSHOT_CARVERS_CHUNK = 9;
    private static final int SNAPSHOT_FEATURES_CHUNK = 10;
    private static final int FEATURE_INDICES = 11;

    private static volatile HarnessController INSTANCE;
    private static final boolean TRACE_PACKETS = System.getenv("MCC_HARNESS_TRACE") != null;

    private final MinecraftServer server;
    private final Path socketPath;
    private final ServerSocketChannel listener;
    private final Thread controlThread;
    private final ArrayBlockingQueue<TickRequest> tickRequests = new ArrayBlockingQueue<>(1);
    private final Map<String, SyntheticClient> clients = new LinkedHashMap<>();
    private final Map<String, SyntheticClient> disconnectedClients = new LinkedHashMap<>();
    private final Map<String, Entity> fixtureEntities = new LinkedHashMap<>();
    private final List<StagedPacket> staged = new ArrayList<>();
    private final List<StagedControl> stagedControls = new ArrayList<>();
    private final List<CapturedPacket> captured = new ArrayList<>();
    private final List<ItemEntity> pendingItemEntities = new ArrayList<>();
    private final Map<String, Integer> pendingChunkAcknowledgements = new LinkedHashMap<>();
    private String suppressInitialReconnectPosition;
    private volatile TickRequest activeRequest;
    private volatile boolean capturing;
    private volatile boolean closed;

    private record StagedPacket(String client, byte[] body) {}
    private record StagedControl(String client, int kind) {}
    private record CapturedPacket(String recipient, byte[] body) {}
    private record Identity(String alias, int entityId, UUID uuid, double x, double y, double z) {}
    private record ChunkSnapshot(
        int chunkX,
        int chunkZ,
        int minY,
        int height,
        List<String> blockPalette,
        int[] blocks,
        List<String> biomePalette,
        int[] biomes
    ) {}
    private record SyntheticClient(
        String alias,
        HarnessConnection connection,
        ServerPlayerEntity player,
        NetworkState<ServerPlayPacketListener> inbound
    ) {}

    private sealed interface Setup permits SetBlock, FillBox, SpawnPlayer, SpawnEntity, SpawnItem, SetPlayerHealth, SetEntityHealth, SetPlayerGameMode, SetHeldStack, SetInventoryStack, SetSelectedHotbarSlot, SetGameRule, SetTime, EnableChunkStreaming {}
    private record SetBlock(int x, short y, int z, String state) implements Setup {}
    private record FillBox(int minX, short minY, int minZ, int maxX, short maxY, int maxZ, String state) implements Setup {}
    private record SpawnPlayer(String id, double x, double y, double z) implements Setup {}
    private record SpawnEntity(String id, String kind, double x, double y, double z, boolean baby, boolean onGround) implements Setup {}
    private record SpawnItem(
        String id,
        String item,
        int count,
        double x,
        double y,
        double z,
        double velocityX,
        double velocityY,
        double velocityZ,
        int pickupDelay,
        int age
    ) implements Setup {}
    private record SetPlayerHealth(String id, float health) implements Setup {}
    private record SetEntityHealth(String id, float health) implements Setup {}
    private record SetPlayerGameMode(String id, String gameMode) implements Setup {}
    private record EnableChunkStreaming() implements Setup {}
    private record SetHeldStack(String id, String item, int count) implements Setup {}
    private record SetInventoryStack(String id, String slot, String item, int count) implements Setup {}
    private record SetSelectedHotbarSlot(String id, int slot) implements Setup {}
    private record SetGameRule(String name, String value) implements Setup {}
    private record SetTime(long value) implements Setup {}
    private record RestoreSpec(String fixture, long seed, long frozenTime, List<String> clients, List<Setup> setup) {}

    private enum TickKind { RESTORE, STEP, SNAPSHOT, SNAPSHOT_NOISE, SNAPSHOT_SURFACE, SNAPSHOT_CARVERS, SNAPSHOT_FEATURES, FEATURE_INDICES, SHUTDOWN }
    private static final class TickRequest {
        final TickKind kind;
        final RestoreSpec restore;
        final int chunkX;
        final int chunkZ;
        final CountDownLatch completed = new CountDownLatch(1);
        volatile Throwable failure;
        volatile List<Identity> identities = List.of();
        volatile List<CapturedPacket> outputs = List.of();
        volatile List<String> featureIndices = List.of();
        volatile ChunkSnapshot snapshot;
        int warmupTicksRemaining;

        TickRequest(TickKind kind, RestoreSpec restore) {
            this(kind, restore, 0, 0);
        }

        TickRequest(TickKind kind, RestoreSpec restore, int chunkX, int chunkZ) {
            this.kind = kind;
            this.restore = restore;
            this.chunkX = chunkX;
            this.chunkZ = chunkZ;
        }
    }

    private HarnessController(MinecraftServer server, Path socketPath) throws IOException {
        this.server = server;
        this.socketPath = socketPath;
        Files.deleteIfExists(socketPath);
        this.listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        this.listener.bind(UnixDomainSocketAddress.of(socketPath));
        this.controlThread = Thread.ofPlatform().name("vanilla-conformance-control").daemon().start(this::serve);
        System.out.println("Vanilla conformance harness ready on unix:" + socketPath);
    }

    public static void start(MinecraftServer server) {
        if (INSTANCE != null) throw new IllegalStateException("Vanilla conformance harness started twice");
        Path socketPath = Path.of(System.getProperty("mcc.harness.socket"));
        try {
            INSTANCE = new HarnessController(server, socketPath);
        } catch (IOException error) {
            throw new IllegalStateException("unable to start Vanilla conformance harness", error);
        }
    }

    public static boolean beforeTick(MinecraftServer server) {
        HarnessController controller = INSTANCE;
        if (controller == null || controller.closed) return false;
        TickRequest current = controller.activeRequest;
        if (current != null && current.kind == TickKind.RESTORE && current.warmupTicksRemaining > 0) {
            ServerWorld world = server.getOverworld();
            for (SyntheticClient client : controller.clients.values()) {
                world.getChunkManager().updatePosition(client.player);
            }
            return false;
        }
        TickRequest request;
        try {
            request = controller.tickRequests.take();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("interrupted while waiting for conformance step", interrupted);
        }
        controller.activeRequest = request;
        try {
            switch (request.kind) {
                case RESTORE -> {
                    controller.restore(request.restore);
                    controller.capturing = false;
                    request.warmupTicksRemaining = 4;
                    return false;
                }
                case STEP -> {
                    controller.captured.clear();
                    controller.capturing = true;
                    controller.materializePendingItems();
                    // Applying the staged C2S packets is part of this tick. A
                    // Vanilla handler may emit S2C packets immediately, before
                    // MinecraftServer.tick advances the world, so capture must
                    // already be active at this boundary.
                    controller.applyStagedControls();
                    controller.applyStagedPackets();
                    return false;
                }
                case SNAPSHOT -> {
                    request.snapshot = controller.snapshotChunk(request.chunkX, request.chunkZ, null);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case SNAPSHOT_NOISE -> {
                    request.snapshot = controller.snapshotChunk(request.chunkX, request.chunkZ, ChunkStatus.NOISE);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case SNAPSHOT_SURFACE -> {
                    request.snapshot = controller.snapshotChunk(request.chunkX, request.chunkZ, ChunkStatus.SURFACE);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case SNAPSHOT_CARVERS -> {
                    request.snapshot = controller.snapshotChunk(request.chunkX, request.chunkZ, ChunkStatus.CARVERS);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case SNAPSHOT_FEATURES -> {
                    request.snapshot = controller.snapshotChunk(request.chunkX, request.chunkZ, ChunkStatus.FEATURES);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case FEATURE_INDICES -> {
                    request.featureIndices = controller.featureIndices();
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
                case SHUTDOWN -> {
                    server.stop(false);
                    request.completed.countDown();
                    controller.activeRequest = null;
                    return true;
                }
            }
        } catch (Throwable failure) {
            controller.capturing = false;
            request.failure = failure;
            request.completed.countDown();
            controller.activeRequest = null;
            return true;
        }
        throw new AssertionError();
    }

    public static void afterTick(MinecraftServer server) {
        HarnessController controller = INSTANCE;
        if (controller == null) return;
        TickRequest request = controller.activeRequest;
        if (request == null) return;
        if (request.kind != TickKind.SHUTDOWN) controller.tickClientHandlers();
        if (TRACE_PACKETS && request.kind == TickKind.STEP) {
            for (SyntheticClient client : controller.clients.values()) {
                System.out.println("Vanilla harness state player=" + client.alias + " position=" + client.player.getPos());
            }
        }
        if (request.kind == TickKind.RESTORE) {
            controller.applyProtocolAcknowledgements();
            request.warmupTicksRemaining -= 1;
            if (request.warmupTicksRemaining > 0) return;
            controller.finishRestore(request.restore);
            request.identities = controller.identities();
        }
        if (request.kind == TickKind.STEP) {
            controller.applyProtocolAcknowledgements();
            // The transportless harness synthesizes chunk acknowledgements at
            // the tick boundary. Re-evaluate Vanilla's entity listeners after
            // those acknowledgements exactly as the normal network/chunk path
            // does for a real client. Any resulting spawn/equipment packets
            // are still produced and encoded by Vanilla itself.
            ServerWorld world = server.getOverworld();
            for (SyntheticClient client : controller.clients.values()) {
                world.getChunkManager().updatePosition(client.player);
            }
            request.outputs = List.copyOf(controller.captured);
        }
        controller.capturing = false;
        request.completed.countDown();
        controller.activeRequest = null;
    }

    public static void closeActive() {
        HarnessController controller = INSTANCE;
        INSTANCE = null;
        if (controller != null) controller.close();
    }

    void capture(String recipient, Packet<?> packet) {
        // A disconnected transport is no longer a conformance recipient even
        // if Vanilla emits into its handler while completing removal.
        if (!clients.containsKey(recipient)) return;
        // ConnectedClientData.createDefault has no saved-player payload, so
        // onPlayerConnect emits a synthetic random-spawn teleport.  The
        // harness restores the fixture position immediately afterward and
        // captures that real Vanilla sync instead.
        if (recipient.equals(suppressInitialReconnectPosition) && packet instanceof PlayerPositionLookS2CPacket) return;
        if (packet instanceof BundlePacket<?> bundle) {
            for (Packet<?> child : bundle.getPackets()) capture(recipient, child);
            return;
        }
        if (packet instanceof ChunkSentS2CPacket) {
            pendingChunkAcknowledgements.merge(recipient, 1, Integer::sum);
        }
        if (!capturing) return;
        if (TRACE_PACKETS) {
            System.out.println("Vanilla harness S2C recipient=" + recipient + " packet=" + packet.getClass().getName());
        }
        NetworkState<ClientPlayPacketListener> outbound = PlayStateFactories.S2C.bind(RegistryByteBuf.makeFactory(server.getRegistryManager()));
        ByteBuf buffer = Unpooled.buffer();
        try {
            @SuppressWarnings({"rawtypes", "unchecked"})
            Packet rawPacket = packet;
            @SuppressWarnings({"rawtypes", "unchecked"})
            NetworkState rawState = outbound;
            rawState.codec().encode(buffer, rawPacket);
            byte[] body = new byte[buffer.readableBytes()];
            buffer.readBytes(body);
            captured.add(new CapturedPacket(recipient, body));
        } finally {
            buffer.release();
        }
    }

    private void serve() {
        try (SocketChannel socket = listener.accept();
             DataInputStream input = new DataInputStream(new BufferedInputStream(Channels.newInputStream(socket)));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(Channels.newOutputStream(socket)))) {
            while (!closed) {
                int command;
                try {
                    command = input.readUnsignedByte();
                } catch (EOFException end) {
                    break;
                }
                switch (command) {
                    case RESTORE -> handleRestore(input, output);
                    case STAGE -> handleStage(input, output);
                    case STEP -> handleStep(output);
                    case CONTROL -> handleControl(input, output);
                    case SNAPSHOT_CHUNK -> handleSnapshotChunk(input, output);
                    case SNAPSHOT_NOISE_CHUNK -> handleSnapshotNoiseChunk(input, output);
                    case SNAPSHOT_SURFACE_CHUNK -> handleSnapshotSurfaceChunk(input, output);
                    case SNAPSHOT_CARVERS_CHUNK -> handleSnapshotCarversChunk(input, output);
                    case SNAPSHOT_FEATURES_CHUNK -> handleSnapshotFeaturesChunk(input, output);
                    case FEATURE_INDICES -> handleFeatureIndices(output);
                    case SHUTDOWN -> {
                        handleShutdown(output);
                        return;
                    }
                    default -> throw new IOException("unknown private harness command " + command);
                }
                output.flush();
            }
        } catch (Throwable failure) {
            if (!closed) failure.printStackTrace(System.err);
        }
    }

    private void handleRestore(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        String fixture = readString(input);
        long seed = input.readLong();
        long frozenTime = input.readLong();
        int clientCount = readCount(input, 64);
        List<String> names = new ArrayList<>(clientCount);
        for (int index = 0; index < clientCount; index++) names.add(readString(input));
        int setupCount = readCount(input, 4096);
        List<Setup> setup = new ArrayList<>(setupCount);
        for (int index = 0; index < setupCount; index++) {
            switch (input.readUnsignedByte()) {
                case 0 -> setup.add(new SetBlock(input.readInt(), input.readShort(), input.readInt(), readString(input)));
                case 1 -> setup.add(new SpawnPlayer(readString(input), input.readDouble(), input.readDouble(), input.readDouble()));
                case 2 -> setup.add(new SpawnEntity(
                    readString(input),
                    readString(input),
                    input.readDouble(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readUnsignedByte() != 0,
                    input.readUnsignedByte() != 0
                ));
                case 3 -> setup.add(new SetHeldStack(readString(input), readString(input), input.readUnsignedByte()));
                case 4 -> setup.add(new SetGameRule(readString(input), readString(input)));
                case 5 -> setup.add(new SetInventoryStack(readString(input), readString(input), readString(input), input.readUnsignedByte()));
                case 6 -> setup.add(new SetSelectedHotbarSlot(readString(input), input.readUnsignedByte()));
                case 7 -> setup.add(new FillBox(
                    input.readInt(), input.readShort(), input.readInt(),
                    input.readInt(), input.readShort(), input.readInt(), readString(input)
                ));
                case 8 -> setup.add(new SetTime(input.readLong()));
                case 9 -> setup.add(new SetPlayerHealth(readString(input), input.readFloat()));
                case 10 -> setup.add(new SetEntityHealth(readString(input), input.readFloat()));
                case 11 -> setup.add(new SetPlayerGameMode(readString(input), readString(input)));
                case 12 -> setup.add(new EnableChunkStreaming());
                case 13 -> setup.add(new SpawnItem(
                    readString(input),
                    readString(input),
                    input.readUnsignedByte(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readDouble(),
                    input.readUnsignedShort(),
                    input.readInt()
                ));
                default -> throw new IOException("unsupported fixture setup operation");
            }
        }
        TickRequest request = submit(new TickRequest(TickKind.RESTORE, new RestoreSpec(fixture, seed, frozenTime, names, setup)));
        if (!writeStatus(output, request.failure)) return;
        output.writeInt(request.identities.size());
        for (Identity identity : request.identities) {
            writeString(output, identity.alias);
            output.writeInt(identity.entityId);
            output.writeLong(identity.uuid.getMostSignificantBits());
            output.writeLong(identity.uuid.getLeastSignificantBits());
            output.writeDouble(identity.x);
            output.writeDouble(identity.y);
            output.writeDouble(identity.z);
        }
    }

    private void handleStage(DataInputStream input, DataOutputStream output) throws IOException {
        String client = readString(input);
        int length = readCount(input, 4 * 1024 * 1024);
        byte[] body = input.readNBytes(length);
        if (body.length != length) throw new EOFException("truncated staged packet");
        synchronized (staged) {
            staged.add(new StagedPacket(client, body));
        }
        writeStatus(output, null);
    }

    private void handleControl(DataInputStream input, DataOutputStream output) throws IOException {
        String client = readString(input);
        int kind = input.readUnsignedByte();
        synchronized (stagedControls) {
            stagedControls.add(new StagedControl(client, kind));
        }
        writeStatus(output, null);
    }

    private void handleStep(DataOutputStream output) throws IOException, InterruptedException {
        TickRequest request = submit(new TickRequest(TickKind.STEP, null));
        if (!writeStatus(output, request.failure)) return;
        output.writeInt(request.outputs.size());
        for (CapturedPacket packet : request.outputs) {
            writeString(output, packet.recipient);
            output.writeInt(packet.body.length);
            output.write(packet.body);
        }
    }

    private void handleSnapshotChunk(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        handleSnapshot(input, output, TickKind.SNAPSHOT);
    }

    private void handleSnapshotNoiseChunk(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        handleSnapshot(input, output, TickKind.SNAPSHOT_NOISE);
    }

    private void handleSnapshotSurfaceChunk(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        handleSnapshot(input, output, TickKind.SNAPSHOT_SURFACE);
    }

    private void handleSnapshotCarversChunk(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        handleSnapshot(input, output, TickKind.SNAPSHOT_CARVERS);
    }

    private void handleSnapshotFeaturesChunk(DataInputStream input, DataOutputStream output) throws IOException, InterruptedException {
        handleSnapshot(input, output, TickKind.SNAPSHOT_FEATURES);
    }

    private void handleFeatureIndices(DataOutputStream output) throws IOException, InterruptedException {
        TickRequest request = submit(new TickRequest(TickKind.FEATURE_INDICES, null));
        if (!writeStatus(output, request.failure)) return;
        output.writeInt(request.featureIndices.size());
        for (String entry : request.featureIndices) writeString(output, entry);
    }

    private void handleSnapshot(DataInputStream input, DataOutputStream output, TickKind kind) throws IOException, InterruptedException {
        int chunkX = input.readInt();
        int chunkZ = input.readInt();
        TickRequest request = submit(new TickRequest(kind, null, chunkX, chunkZ));
        if (!writeStatus(output, request.failure)) return;
        ChunkSnapshot snapshot = request.snapshot;
        output.writeInt(snapshot.chunkX);
        output.writeInt(snapshot.chunkZ);
        output.writeInt(snapshot.minY);
        output.writeInt(snapshot.height);
        output.writeInt(snapshot.blockPalette.size());
        for (String state : snapshot.blockPalette) writeString(output, state);
        output.writeInt(snapshot.blocks.length);
        for (int block : snapshot.blocks) output.writeInt(block);
        output.writeInt(snapshot.biomePalette.size());
        for (String biome : snapshot.biomePalette) writeString(output, biome);
        output.writeInt(snapshot.biomes.length);
        for (int biome : snapshot.biomes) output.writeInt(biome);
    }

    private void handleShutdown(DataOutputStream output) throws IOException, InterruptedException {
        TickRequest request = submit(new TickRequest(TickKind.SHUTDOWN, null));
        writeStatus(output, request.failure);
    }

    private TickRequest submit(TickRequest request) throws InterruptedException {
        tickRequests.put(request);
        request.completed.await();
        return request;
    }

    private List<String> featureIndices() {
        ChunkGenerator generator = server.getOverworld().getChunkManager().getChunkGenerator();
        List<RegistryEntry<Biome>> biomes = new ArrayList<>(generator.getBiomeSource().getBiomes());
        List<PlacedFeatureIndexer.IndexedFeatures> steps = PlacedFeatureIndexer.collectIndexedFeatures(
            biomes,
            biome -> generator.getGenerationSettings(biome).getFeatures(),
            true
        );
        Registry<PlacedFeature> registry = server.getRegistryManager().getOrThrow(RegistryKeys.PLACED_FEATURE);
        List<String> result = new ArrayList<>();
        for (int step = 0; step < steps.size(); step++) {
            List<PlacedFeature> features = steps.get(step).features();
            for (int index = 0; index < features.size(); index++) {
                Identifier id = registry.getId(features.get(index));
                if (id == null) throw new IllegalStateException("unregistered placed feature at step " + step + " index " + index);
                PlacedFeature placed = features.get(index);
                String placedJson = PlacedFeature.CODEC
                    .encodeStart(server.getRegistryManager().getOps(JsonOps.INSTANCE), placed)
                    .getOrThrow()
                    .toString();
                ConfiguredFeature<?, ?> configured = placed.feature().value();
                String configuredJson = ConfiguredFeature.CODEC
                    .encodeStart(server.getRegistryManager().getOps(JsonOps.INSTANCE), configured)
                    .getOrThrow()
                    .toString();
                result.add(step + " " + index + " " + id + "\t" + placedJson + "\t" + configuredJson);
            }
        }
        List<Identifier> ids = new ArrayList<>(registry.getIds());
        ids.sort(Comparator.naturalOrder());
        for (Identifier id : ids) {
            PlacedFeature placed = registry.get(id);
            if (placed == null) throw new IllegalStateException("missing placed feature " + id);
            String placedJson = PlacedFeature.CODEC
                .encodeStart(server.getRegistryManager().getOps(JsonOps.INSTANCE), placed)
                .getOrThrow()
                .toString();
            ConfiguredFeature<?, ?> configured = placed.feature().value();
            String configuredJson = ConfiguredFeature.CODEC
                .encodeStart(server.getRegistryManager().getOps(JsonOps.INSTANCE), configured)
                .getOrThrow()
                .toString();
            result.add("registry " + id + "\t" + placedJson + "\t" + configuredJson);
        }
        return List.copyOf(result);
    }

    private void restore(RestoreSpec spec) {
        if (!clients.isEmpty()) throw new IllegalStateException("a Vanilla harness process restores exactly one fixture");
        ServerWorld world = server.getOverworld();
        if (world.getSeed() != spec.seed) {
            throw new IllegalStateException("fixture " + spec.fixture + " requires seed " + spec.seed + " but Vanilla loaded " + world.getSeed());
        }
        world.setTimeOfDay(spec.frozenTime);
        world.getGameRules().get(GameRules.RANDOM_TICK_SPEED).set(0, server);
        world.getGameRules().get(GameRules.DO_MOB_SPAWNING).set(false, server);
        for (String alias : spec.clients) createClient(alias, world);
        for (Setup operation : spec.setup) {
            if (operation instanceof SpawnPlayer) applySetup(world, operation);
        }
        // Vanilla updates an observer's entity listeners before it updates
        // that observer's chunk filter. Fixture teleports can therefore leave
        // the final moved player using its pre-fixture filter unless every
        // player receives a second normal tracking update after all positions
        // are installed.
        for (SyntheticClient client : clients.values()) {
            world.getChunkManager().updatePosition(client.player);
        }
        for (SyntheticClient client : clients.values()) {
            // Complete the login teleport that a real client acknowledges
            // before it begins sending play actions.
            ((ServerPlayNetworkHandlerAccessor) client.player.networkHandler).lightningRodHarnessRequestedTeleportPos(null);
            client.player.onTeleportationDone();
        }
    }

    private ChunkSnapshot snapshotChunk(int chunkX, int chunkZ, ChunkStatus status) {
        ServerWorld world = server.getOverworld();
        Chunk chunk = status == null
            ? world.getChunk(chunkX, chunkZ)
            : world.getChunkManager().getChunk(chunkX, chunkZ, status, true);
        int minY = world.getBottomY();
        int height = world.getHeight();

        Map<String, Integer> blockIds = new LinkedHashMap<>();
        int[] blocks = new int[16 * 16 * height];
        BlockPos.Mutable position = new BlockPos.Mutable();
        int blockIndex = 0;
        for (int y = minY; y < minY + height; y++) {
            for (int z = 0; z < 16; z++) {
                for (int x = 0; x < 16; x++) {
                    position.set((chunkX << 4) + x, y, (chunkZ << 4) + z);
                    String state = canonicalBlockState(chunk.getBlockState(position));
                    blocks[blockIndex++] = blockIds.computeIfAbsent(state, ignored -> blockIds.size());
                }
            }
        }

        int biomeHeight = height >> 2;
        Map<String, Integer> biomeIds = new LinkedHashMap<>();
        int[] biomes = new int[4 * 4 * biomeHeight];
        int biomeIndex = 0;
        int quartX = chunkX << 2;
        int quartZ = chunkZ << 2;
        int minQuartY = minY >> 2;
        for (int y = 0; y < biomeHeight; y++) {
            for (int z = 0; z < 4; z++) {
                for (int x = 0; x < 4; x++) {
                    String biome = chunk.getBiomeForNoiseGen(quartX + x, minQuartY + y, quartZ + z)
                        .getKey()
                        .orElseThrow(() -> new IllegalStateException("generated biome has no registry key"))
                        .getValue()
                        .toString();
                    biomes[biomeIndex++] = biomeIds.computeIfAbsent(biome, ignored -> biomeIds.size());
                }
            }
        }

        return new ChunkSnapshot(
            chunkX,
            chunkZ,
            minY,
            height,
            List.copyOf(blockIds.keySet()),
            blocks,
            List.copyOf(biomeIds.keySet()),
            biomes
        );
    }

    private static String canonicalBlockState(BlockState state) {
        StringBuilder result = new StringBuilder(Registries.BLOCK.getId(state.getBlock()).toString());
        if (state.getEntries().isEmpty()) return result.toString();
        result.append('[');
        boolean first = true;
        List<Map.Entry<Property<?>, Comparable<?>>> entries = new ArrayList<>(state.getEntries().entrySet());
        entries.sort(Comparator.comparing(entry -> entry.getKey().getName()));
        for (Map.Entry<Property<?>, Comparable<?>> entry : entries) {
            if (!first) result.append(',');
            first = false;
            result.append(entry.getKey().getName()).append('=');
            appendPropertyValue(result, entry.getKey(), entry.getValue());
        }
        return result.append(']').toString();
    }

    private static <T extends Comparable<T>> void appendPropertyValue(
        StringBuilder output,
        Property<T> property,
        Comparable<?> value
    ) {
        output.append(property.name(property.getType().cast(value)));
    }

    private void finishRestore(RestoreSpec spec) {
        ServerWorld world = server.getOverworld();
        world.setTimeOfDay(spec.frozenTime);
        for (Setup operation : spec.setup) {
            if (!(operation instanceof SpawnPlayer)) applySetup(world, operation);
        }
        for (SyntheticClient client : clients.values()) {
            client.player.networkHandler.syncWithPlayerPosition();
            ((ServerPlayNetworkHandlerAccessor) client.player.networkHandler).lightningRodHarnessRequestedTeleportPos(null);
            client.player.onTeleportationDone();
            world.getChunkManager().updatePosition(client.player);
        }
    }

    private void createClient(String alias, ServerWorld world) {
        // Never load a player save left by an earlier disposable harness run.
        // Runtime identity is reported to Zig explicitly, so UUID stability is
        // neither required nor desirable here.
        UUID uuid = UUID.randomUUID();
        GameProfile profile = new GameProfile(uuid, alias);
        SyncedClientOptions options = SyncedClientOptions.createDefault();
        ServerPlayerEntity player = new ServerPlayerEntity(server, world, profile, options);
        HarnessConnection connection = new HarnessConnection(this, alias);
        ConnectedClientData data = ConnectedClientData.createDefault(profile, false);
        server.getPlayerManager().onPlayerConnect(connection, player, data);
        // A real client sends PlayerLoaded after applying GameJoin. The
        // transportless harness starts directly in the usable play state.
        player.setLoaded(true);
        NetworkState<ServerPlayPacketListener> inbound = PlayStateFactories.C2S.bind(RegistryByteBuf.makeFactory(server.getRegistryManager()), player.networkHandler);
        clients.put(alias, new SyntheticClient(alias, connection, player, inbound));
    }

    private void applySetup(ServerWorld world, Setup setup) {
        if (setup instanceof SetBlock block) {
            world.setBlockState(new BlockPos(block.x, block.y, block.z), fixtureBlockState(block.state), Block.NOTIFY_ALL);
        } else if (setup instanceof FillBox box) {
            if (box.minX > box.maxX || box.minY > box.maxY || box.minZ > box.maxZ)
                throw new IllegalArgumentException("invalid fixture fill box");
            long volume = (long) (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1) * (box.maxZ - box.minZ + 1);
            if (volume > 1_000_000) throw new IllegalArgumentException("fixture fill box is too large");
            BlockState state = fixtureBlockState(box.state);
            for (int y = box.minY; y <= box.maxY; y++) {
                for (int z = box.minZ; z <= box.maxZ; z++) {
                    for (int x = box.minX; x <= box.maxX; x++)
                        world.setBlockState(new BlockPos(x, y, z), state, 0);
                }
            }
        } else if (setup instanceof SpawnPlayer spawn) {
            SyntheticClient client = requireClient(spawn.id);
            client.player.refreshPositionAndAngles(spawn.x, spawn.y, spawn.z, 0, 0);
            // refreshPositionAndAngles bypasses the normal movement packet
            // path. Keep Vanilla's chunk/entity tracking position in sync with
            // the fixture position just as ServerPlayNetworkHandler does after
            // accepting a real client move.
            world.getChunkManager().updatePosition(client.player);
            client.player.networkHandler.syncWithPlayerPosition();
        } else if (setup instanceof SpawnEntity spawn) {
            if (fixtureEntities.containsKey(spawn.id)) throw new IllegalArgumentException("duplicate fixture entity " + spawn.id);
            EntityType<?> type = Registries.ENTITY_TYPE.get(Identifier.of(spawn.kind));
            if (type == null) throw new IllegalArgumentException("unknown fixture entity type " + spawn.kind);
            Entity entity = type.create(world, SpawnReason.COMMAND);
            if (entity == null) throw new IllegalArgumentException("fixture entity type cannot be created " + spawn.kind);
            entity.refreshPositionAndAngles(spawn.x, spawn.y, spawn.z, 0, 0);
            entity.setOnGround(spawn.onGround);
            if (spawn.baby && entity instanceof PassiveEntity passive) passive.setBaby(true);
            if (!world.spawnEntity(entity)) throw new IllegalStateException("failed to spawn fixture entity " + spawn.id);
            fixtureEntities.put(spawn.id, entity);
        } else if (setup instanceof SpawnItem spawn) {
            if (fixtureEntities.containsKey(spawn.id)) throw new IllegalArgumentException("duplicate fixture entity " + spawn.id);
            Item item = Registries.ITEM.get(Identifier.of(spawn.item));
            if (item == null) throw new IllegalArgumentException("unknown fixture item " + spawn.item);
            ItemEntity entity = new ItemEntity(
                world,
                spawn.x,
                spawn.y,
                spawn.z,
                new ItemStack(item, spawn.count),
                spawn.velocityX,
                spawn.velocityY,
                spawn.velocityZ
            );
            entity.setPickupDelay(spawn.pickupDelay);
            ((ItemEntityAccessor) entity).lightningRodHarnessSetItemAge(spawn.age);
            fixtureEntities.put(spawn.id, entity);
            pendingItemEntities.add(entity);
        } else if (setup instanceof SetPlayerHealth health) {
            requireClient(health.id).player.setHealth(health.health);
        } else if (setup instanceof SetEntityHealth health) {
            Entity entity = fixtureEntities.get(health.id);
            if (!(entity instanceof LivingEntity living)) throw new IllegalArgumentException("fixture entity is not living " + health.id);
            living.setHealth(health.health);
        } else if (setup instanceof SetPlayerGameMode entry) {
            GameMode gameMode = switch (entry.gameMode) {
                case "survival" -> GameMode.SURVIVAL;
                case "creative" -> GameMode.CREATIVE;
                case "adventure" -> GameMode.ADVENTURE;
                case "spectator" -> GameMode.SPECTATOR;
                default -> throw new IllegalArgumentException("unknown fixture game mode " + entry.gameMode);
            };
            requireClient(entry.id).player.changeGameMode(gameMode);
        } else if (setup instanceof SetHeldStack held) {
            SyntheticClient client = requireClient(held.id);
            Item item = Registries.ITEM.get(Identifier.of(held.item));
            if (item == null) throw new IllegalArgumentException("unknown fixture item " + held.item);
            PlayerInventory inventory = client.player.getInventory();
            inventory.setSelectedSlot(3);
            inventory.setSelectedStack(new ItemStack(item, held.count));
            inventory.markDirty();
        } else if (setup instanceof SetInventoryStack entry) {
            SyntheticClient client = requireClient(entry.id);
            Item item = Registries.ITEM.get(Identifier.of(entry.item));
            int slot = canonicalInventorySlot(entry.slot);
            ItemStack stack = entry.count == 0 ? ItemStack.EMPTY : new ItemStack(item, entry.count);
            if (entry.slot.charAt(0) == 'g') {
                client.player.playerScreenHandler.getSlot(slot).setStack(stack);
            } else {
                client.player.getInventory().setStack(slot, stack);
                client.player.getInventory().markDirty();
            }
        } else if (setup instanceof SetSelectedHotbarSlot selected) {
            if (selected.slot < 0 || selected.slot > 8) throw new IllegalArgumentException("invalid selected hotbar slot");
            SyntheticClient client = requireClient(selected.id);
            client.player.getInventory().setSelectedSlot(selected.slot);
            client.player.getInventory().markDirty();
        } else if (setup instanceof SetGameRule rule) {
            if (rule.name.equals("randomTickSpeed")) {
                world.getGameRules().get(GameRules.RANDOM_TICK_SPEED).set(Integer.parseInt(rule.value), server);
                return;
            }
            boolean value = switch (rule.value) {
                case "true" -> true;
                case "false" -> false;
                default -> throw new IllegalArgumentException("invalid fixture gamerule value " + rule.value);
            };
            if (rule.name.equals("doRandomTicks")) {
                world.getGameRules().get(GameRules.RANDOM_TICK_SPEED).set(value ? GameRules.DEFAULT_RANDOM_TICK_SPEED : 0, server);
            } else if (rule.name.equals("doMobSpawning")) {
                world.getGameRules().get(GameRules.DO_MOB_SPAWNING).set(value, server);
            } else if (rule.name.equals("naturalRegeneration")) {
                world.getGameRules().get(GameRules.NATURAL_REGENERATION).set(value, server);
            } else if (rule.name.equals("doDaylightCycle")) {
                world.getGameRules().get(GameRules.DO_DAYLIGHT_CYCLE).set(value, server);
            } else {
                throw new IllegalArgumentException("unknown fixture gamerule " + rule.name);
            }
        } else if (setup instanceof SetTime time) {
            world.setTimeOfDay(time.value);
        } else if (setup instanceof EnableChunkStreaming) {
            // Vanilla's synthetic clients already receive the production
            // chunk/light stream. This fixture flag enables the equivalent
            // path only for in-process server adapters.
        }
    }

    private static BlockState fixtureBlockState(String canonical) {
        int propertiesAt = canonical.indexOf('[');
        String id = propertiesAt < 0 ? canonical : canonical.substring(0, propertiesAt);
        Block block = Registries.BLOCK.get(Identifier.of(id));
        if (block == null) throw new IllegalArgumentException("unknown fixture block " + canonical);
        BlockState state = block.getDefaultState();
        if (propertiesAt < 0) return state;
        if (!canonical.endsWith("]")) throw new IllegalArgumentException("invalid fixture block state " + canonical);
        String properties = canonical.substring(propertiesAt + 1, canonical.length() - 1);
        for (String assignment : properties.split(",")) {
            String[] pair = assignment.split("=", 2);
            if (pair.length != 2) throw new IllegalArgumentException("invalid fixture block property " + assignment);
            Property<?> property = block.getStateManager().getProperty(pair[0]);
            if (property == null) throw new IllegalArgumentException("unknown property " + pair[0] + " for fixture block " + id);
            state = withParsedProperty(state, property, pair[1], canonical);
        }
        return state;
    }

    private static <T extends Comparable<T>> BlockState withParsedProperty(
        BlockState state, Property<T> property, String value, String canonical
    ) {
        T parsed = property.parse(value).orElseThrow(
            () -> new IllegalArgumentException("invalid property value in fixture block " + canonical)
        );
        return state.with(property, parsed);
    }

    private static int canonicalInventorySlot(String value) {
        if (value.length() < 2) throw new IllegalArgumentException("invalid canonical inventory slot " + value);
        int index = Integer.parseInt(value.substring(1));
        return switch (value.charAt(0)) {
            case 'h' -> {
                if (index < 0 || index >= 9) throw new IllegalArgumentException("invalid hotbar slot " + value);
                yield index;
            }
            case 'm' -> {
                if (index < 0 || index >= 27) throw new IllegalArgumentException("invalid main inventory slot " + value);
                yield 9 + index;
            }
            case 'g' -> {
                if (index < 0 || index >= 4) throw new IllegalArgumentException("invalid crafting grid slot " + value);
                yield 1 + index;
            }
            default -> throw new IllegalArgumentException("invalid canonical inventory slot " + value);
        };
    }

    private void applyStagedPackets() {
        List<StagedPacket> packets;
        synchronized (staged) {
            packets = List.copyOf(staged);
            staged.clear();
        }
        for (StagedPacket stagedPacket : packets) {
            SyntheticClient client = requireClient(stagedPacket.client);
            ByteBuf buffer = Unpooled.wrappedBuffer(stagedPacket.body);
            try {
                Packet<? super ServerPlayPacketListener> packet = client.inbound.codec().decode(buffer);
                if (buffer.isReadable()) throw new IllegalArgumentException("staged packet has " + buffer.readableBytes() + " trailing bytes");
                packet.apply(client.player.networkHandler);
            } finally {
                buffer.release();
            }
        }
    }

    private void materializePendingItems() {
        if (pendingItemEntities.isEmpty()) return;
        ServerWorld world = server.getOverworld();
        for (ItemEntity entity : pendingItemEntities) {
            if (!world.spawnEntity(entity))
                throw new IllegalStateException("failed to materialize fixture item " + entity.getUuidAsString());
        }
        pendingItemEntities.clear();
    }

    private void applyStagedControls() {
        List<StagedControl> controls;
        synchronized (stagedControls) {
            controls = List.copyOf(stagedControls);
            stagedControls.clear();
        }
        for (StagedControl control : controls) {
            if (control.kind == 0) {
                SyntheticClient client = requireClient(control.client);
                clients.remove(control.client);
                disconnectedClients.put(control.client, client);
                client.player.networkHandler.onDisconnected(new DisconnectionInfo(Text.literal("Disconnected")));
            } else if (control.kind == 1) {
                SyntheticClient previous = disconnectedClients.remove(control.client);
                if (previous == null) throw new IllegalArgumentException("harness client is not disconnected " + control.client);
                ServerWorld world = server.getOverworld();
                ServerPlayerEntity player = new ServerPlayerEntity(server, world, previous.player.getGameProfile(), SyncedClientOptions.createDefault());
                player.setId(previous.player.getId());
                // A real reconnect loads persistent player state before the
                // player manager emits the join packets.  Doing this after
                // onPlayerConnect would capture an empty inventory/equipment
                // bootstrap and only mutate the server-side object afterward.
                player.copyFrom(previous.player, false);
                player.getInventory().clone(previous.player.getInventory());
                player.refreshPositionAndAngles(previous.player.getX(), previous.player.getY(), previous.player.getZ(), previous.player.getYaw(), previous.player.getPitch());
                HarnessConnection connection = new HarnessConnection(this, control.client);
                ConnectedClientData data = ConnectedClientData.createDefault(previous.player.getGameProfile(), false);
                // Register the transport before Vanilla emits the login
                // bootstrap. capture() intentionally ignores recipients not
                // in this map, so inserting only after onPlayerConnect loses
                // the reconnecting player's own inventory and position.
                clients.put(control.client, new SyntheticClient(control.client, connection, player, null));
                suppressInitialReconnectPosition = control.client;
                server.getPlayerManager().onPlayerConnect(connection, player, data);
                suppressInitialReconnectPosition = null;
                player.refreshPositionAndAngles(previous.player.getX(), previous.player.getY(), previous.player.getZ(), previous.player.getYaw(), previous.player.getPitch());
                new PlayerLoadedC2SPacket().apply(player.networkHandler);
                ((ServerPlayNetworkHandlerAccessor) player.networkHandler).lightningRodHarnessRequestedTeleportPos(null);
                player.onTeleportationDone();
                player.networkHandler.requestTeleport(
                    previous.player.getX(), previous.player.getY(), previous.player.getZ(),
                    previous.player.getYaw(), previous.player.getPitch()
                );
                ((ServerPlayNetworkHandlerAccessor) player.networkHandler).lightningRodHarnessRequestedTeleportPos(null);
                player.onTeleportationDone();
                world.getChunkManager().updatePosition(player);
                // Refresh every observer after the reconnect position is
                // final. Vanilla's entity tracker and chunk filter are
                // updated in separate passes; a single update of only the
                // moved player can leave its view anchored at the synthetic
                // login spawn for this tick.
                for (SyntheticClient client : clients.values()) {
                    world.getChunkManager().updatePosition(client.player);
                }
                NetworkState<ServerPlayPacketListener> inbound = PlayStateFactories.C2S.bind(RegistryByteBuf.makeFactory(server.getRegistryManager()), player.networkHandler);
                clients.put(control.client, new SyntheticClient(control.client, connection, player, inbound));
            } else {
                throw new IllegalArgumentException("unsupported harness lifecycle control " + control.kind);
            }
        }
    }

    private void tickClientHandlers() {
        for (SyntheticClient client : clients.values()) client.player.networkHandler.tick();
    }

    private void applyProtocolAcknowledgements() {
        for (Map.Entry<String, Integer> entry : pendingChunkAcknowledgements.entrySet()) {
            SyntheticClient client = clients.get(entry.getKey());
            if (client == null) continue;
            for (int index = 0; index < entry.getValue(); index++) {
                new AcknowledgeChunksC2SPacket(64.0f).apply(client.player.networkHandler);
            }
        }
        pendingChunkAcknowledgements.clear();
    }

    private SyntheticClient requireClient(String alias) {
        SyntheticClient client = clients.get(alias);
        if (client == null) throw new IllegalArgumentException("unknown harness client " + alias);
        return client;
    }

    private List<Identity> identities() {
        List<Identity> result = new ArrayList<>(clients.size() + fixtureEntities.size());
        for (SyntheticClient client : clients.values()) {
            ServerPlayerEntity player = client.player;
            result.add(new Identity(client.alias, player.getId(), player.getUuid(), player.getX(), player.getY(), player.getZ()));
        }
        for (Map.Entry<String, Entity> entry : fixtureEntities.entrySet()) {
            Entity entity = entry.getValue();
            result.add(new Identity(entry.getKey(), entity.getId(), entity.getUuid(), entity.getX(), entity.getY(), entity.getZ()));
        }
        return List.copyOf(result);
    }

    private static int readCount(DataInputStream input, int maximum) throws IOException {
        int value = input.readInt();
        if (value < 0 || value > maximum) throw new IOException("private harness count outside bounds: " + value);
        return value;
    }

    private static String readString(DataInputStream input) throws IOException {
        int length = readCount(input, 1024 * 1024);
        byte[] bytes = input.readNBytes(length);
        if (bytes.length != length) throw new EOFException("truncated private harness string");
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void writeString(DataOutputStream output, String value) throws IOException {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        output.writeInt(bytes.length);
        output.write(bytes);
    }

    private static boolean writeStatus(DataOutputStream output, Throwable failure) throws IOException {
        if (failure == null) {
            output.writeByte(0);
            return true;
        }
        output.writeByte(1);
        writeString(output, failure.toString());
        failure.printStackTrace(System.err);
        return false;
    }

    @Override
    public void close() {
        closed = true;
        try {
            listener.close();
        } catch (IOException ignored) {}
        try {
            Files.deleteIfExists(socketPath);
        } catch (IOException ignored) {}
    }
}
