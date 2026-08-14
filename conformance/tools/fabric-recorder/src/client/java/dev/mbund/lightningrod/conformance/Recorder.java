package dev.mbund.lightningrod.conformance;

import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.screen.multiplayer.ConnectScreen;
import net.minecraft.client.network.ServerAddress;
import net.minecraft.client.network.ServerInfo;
import net.minecraft.entity.ItemEntity;
import net.minecraft.registry.Registries;
import net.minecraft.util.math.BlockPos;
import net.minecraft.util.math.Direction;
import net.minecraft.world.chunk.ChunkStatus;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

/** Fabric owns automation and raw observation only. Zig decodes, canonicalizes,
 * cleans up, and writes the immutable golden. */
public final class Recorder {
    private record RawPacket(long tick, String direction, String peer, byte[] payload) {}
    private static final Recorder INSTANCE = new Recorder();
    private final List<RawPacket> packets = new ArrayList<>();
    private Scenario plan;
    private String client;
    private Path output;
    private String server;
    private volatile long tick;
    private boolean enabled;
    private boolean written;
    private boolean captureStarted;
    private boolean connected;
    private boolean connectAttempted;
    private boolean networkObserved;
    private int startupWaitTicks;
    private int connectionWaitTicks;

    public static Recorder instance() { return INSTANCE; }

    public void configureFromSystemProperties() {
        String scenario = System.getProperty("mcc.scenario");
        if (scenario == null || scenario.isBlank()) return;
        try {
            plan = Scenario.read(Path.of(scenario));
            client = System.getProperty("mcc.client", plan.clients().getFirst());
            if (!plan.clients().contains(client)) throw new IllegalArgumentException("mcc.client is not declared by scenario");
            output = Path.of(System.getProperty("mcc.output", scenario + ".capture"));
            server = System.getProperty("mcc.server");
            enabled = true;
        } catch (IOException | IllegalArgumentException error) {
            throw new IllegalStateException("invalid conformance scenario", error);
        }
    }

    public synchronized void inboundRaw(byte[] payload) {
        if (enabled && captureStarted && !written) packets.add(new RawPacket(tick, "clientbound", client, payload));
    }

    public synchronized void outboundRaw(byte[] payload) {
        if (enabled && captureStarted && !written) packets.add(new RawPacket(tick, "serverbound", client, payload));
    }

    public void startTick(MinecraftClient minecraft) {
        if (!enabled || written) return;
        if (!connectAttempted && server != null) {
            if (!minecraft.isFinishedLoading() || minecraft.getOverlay() != null) {
                if (++startupWaitTicks % 100 == 0) System.out.println("conformance recorder waiting for client startup");
                return;
            }
            connectAttempted = true;
            captureStarted = true;
            ServerAddress address = ServerAddress.parse(server);
            if (address == null) throw new IllegalStateException("invalid mcc.server address");
            ConnectScreen.connect(minecraft.currentScreen, minecraft, address,
                new ServerInfo("Conformance recorder", server, ServerInfo.ServerType.OTHER), false, null);
            return;
        }
        if (minecraft.getNetworkHandler() != null) networkObserved = true;
        if (networkObserved && minecraft.getNetworkHandler() == null && !connected) {
            write(minecraft);
            minecraft.scheduleStop();
            return;
        }
        if (!connected && ++connectionWaitTicks == 700) {
            write(minecraft);
            minecraft.scheduleStop();
            return;
        }
        if (minecraft.player == null) return;
        connected = true;
        for (Scenario.Move move : plan.moves()) if (move.client().equals(client) && move.tick() == tick)
            minecraft.player.setPosition(move.x(), move.y(), move.z());
        for (Scenario.PlayerAction action : plan.actions()) if (action.client().equals(client) && action.tick() == tick) {
            if (minecraft.interactionManager == null) throw new IllegalStateException("no interaction manager after login");
            BlockPos pos = new BlockPos(action.x(), action.y(), action.z());
            switch (action.action()) {
                case "start_destroy_block" -> minecraft.interactionManager.attackBlock(pos, Direction.UP);
                case "abort_destroy_block" -> minecraft.interactionManager.cancelBlockBreaking();
                default -> throw new IllegalStateException("unsupported player_action " + action.action());
            }
        }
        for (Scenario.Command command : plan.commands()) if (command.client().equals(client) && command.tick() == tick)
            minecraft.player.networkHandler.sendChatCommand(command.value().replace("%20", " "));
    }

    public void endTick(MinecraftClient minecraft) {
        if (!enabled || written || !connected) return;
        if (tick == plan.finalTick()) write(minecraft);
        tick++;
    }

    private synchronized void write(MinecraftClient minecraft) {
        written = true;
        List<String> document = new ArrayList<>();
        document.add("mcc-capture-v1");
        document.add("minecraft 1.21.8");
        document.add("fixture " + plan.fixture());
        document.add("client " + client);
        document.add("end " + plan.finalTick());
        if (minecraft.world != null) minecraft.world.getPlayers().forEach(player ->
            document.add("identity " + player.getGameProfile().getName() + " " + player.getId()
                + " " + player.getX() + " " + player.getY() + " " + player.getZ()));
        if (minecraft.world != null && minecraft.player != null)
            minecraft.world.getEntitiesByClass(ItemEntity.class, minecraft.player.getBoundingBox().expand(512), entity -> true).forEach(entity ->
                document.add("item " + entity.getId() + " " + Registries.ITEM.getId(entity.getStack().getItem())
                    + " " + entity.getStack().getCount() + " " + entity.getX() + " " + entity.getY() + " " + entity.getZ()));
        verifyLoadedTerrain(minecraft, document);
        HexFormat hex = HexFormat.of();
        for (RawPacket packet : packets)
            document.add("packet " + packet.tick() + " " + packet.direction() + " " + packet.peer() + " " + hex.formatHex(packet.payload()));
        try {
            if (output.getParent() != null) Files.createDirectories(output.getParent());
            Files.writeString(output, String.join("\n", document) + "\n", StandardCharsets.UTF_8);
            System.out.println("wrote raw conformance capture " + output);
        } catch (IOException error) {
            throw new IllegalStateException("unable to write raw capture " + output, error);
        }
    }

    private void verifyLoadedTerrain(MinecraftClient minecraft, List<String> document) {
        if (minecraft.world == null || minecraft.player == null) return;
        int centerX = Math.floorDiv(minecraft.player.getBlockX(), 16);
        int centerZ = Math.floorDiv(minecraft.player.getBlockZ(), 16);
        int loaded = 0;
        for (int z = centerZ - 32; z <= centerZ + 32; z++) {
            for (int x = centerX - 32; x <= centerX + 32; x++) {
                boolean present = minecraft.world.getChunkManager()
                    .getChunk(x, z, ChunkStatus.FULL, false) != null;
                if (Math.abs(x - centerX) <= 1 && Math.abs(z - centerZ) <= 1 && !present)
                    throw new IllegalStateException("missing spawn-neighborhood chunk " + x + "," + z);
                if (!present) continue;
                loaded++;
                int topNonAir = 0;
                int topY = minecraft.world.getTopYInclusive();
                for (int localZ = 0; localZ < 16; localZ++) {
                    for (int localX = 0; localX < 16; localX++) {
                        if (!minecraft.world.getBlockState(new BlockPos(
                            x * 16 + localX, topY, z * 16 + localZ)).isAir()) topNonAir++;
                    }
                }
                if (topNonAir != 0)
                    throw new IllegalStateException("solid world-height chunk column " + x + "," + z);
                document.add("client_chunk " + x + " " + z + " top_non_air " + topNonAir);
            }
        }
        if (loaded < 9) throw new IllegalStateException("fewer than 3x3 chunks loaded");
    }
}
