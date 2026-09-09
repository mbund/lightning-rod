package dev.mbund.lightningrod.conformance;

import java.io.IOException;
import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import dev.mbund.lightningrod.conformance.mixin.BossBarHudAccessor;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.hud.ClientBossBar;
import net.minecraft.client.gui.screen.TitleScreen;
import net.minecraft.client.gui.screen.DisconnectedScreen;
import net.minecraft.client.gui.screen.ingame.HandledScreen;
import net.minecraft.client.gui.screen.ingame.InventoryScreen;
import net.minecraft.client.gui.screen.multiplayer.ConnectScreen;
import net.minecraft.client.network.ServerAddress;
import net.minecraft.client.network.ServerInfo;
import net.minecraft.client.util.ScreenshotRecorder;
import net.minecraft.util.math.BlockPos;
import net.minecraft.entity.boss.BossBar;
import net.minecraft.text.Text;
import net.minecraft.world.Heightmap;
import net.minecraft.world.LightType;
import net.minecraft.world.chunk.ChunkStatus;

public final class Recorder {
    private static final Recorder INSTANCE = new Recorder();
    private static final long DEFAULT_MAXIMUM_CAPTURE_BYTES = 32L * 1024L * 1024L;
    private final List<String> packets = new ArrayList<>();
    private final List<String> pendingScreenshots = new ArrayList<>();
    private boolean resultPublished;
    private boolean resultPassed;
    private String resultReason;
    private Path output;
    private Path eventsPath;
    private Path artifacts;
    private BufferedWriter events;
    private String peer = "client";
    private String scenario = "chunks";
    private String server;
    private List<String> expectedPeers = List.of("client");
    private long tick;
    private long playTick = -1;
    private long firstChunkTick = -1;
    private long terrainTick = -1;
    private long targetTick = -1;
    private long connectNanos;
    private long playNanos;
    private long firstChunkNanos;
    private long terrainNanos;
    private long targetNanos;
    private int targetLoaded;
    private long lastProgressTick = -1;
    private long reloadTick = -1;
    private long capturedBytes;
    private long maximumCaptureBytes = DEFAULT_MAXIMUM_CAPTURE_BYTES;
    private int targetChunks = 256;
    private int minimumRadius = 2;
    private int maximumStallTicks = 100;
    private int maximumStreamTicks = 0;
    private int maximumTerrainTicks = 40;
    private int minimumSoakTicks = 0;
    private int timeoutTicks = 2400;
    private int connectTick = 40;
    private int lastLoaded = -1;
    private int lastMissing = -1;
    private int maximumBossBars;
    private String lastPhase = "starting";
    private volatile String protocolPhase = "disconnected";
    private String lastScreen = "";
    private boolean openedInventory;
    private boolean readyPublished;
    private long inventoryTick = -1;
    private boolean sawConfiguration;
    private boolean reloadSent;
    private boolean completed;
    private boolean chatSent;
    private final List<String> receivedChat = new ArrayList<>();
    private boolean chatInvalid;
    private long chatWalkTick = -1;
    private boolean connectionAttempted;
    private boolean enabled;
    private boolean written;
    private boolean fatalReasonReceived;
    private boolean encryptionRequested;
    private boolean streamDeadlineMissed;
    private long stopTick = -1;
    private int observedChunkPackets;
    private int observedChunkBoundaries;
    private int observedReadinessEvents;
    public static Recorder instance() { return INSTANCE; }
    public void configure() {
        String value = System.getProperty("mcc.events");
        if (value == null || value.isBlank()) return;
        eventsPath = Path.of(value);
        output = optionalPath("mcc.output");
        artifacts = Path.of(System.getProperty("mcc.artifacts", eventsPath.getParent().toString()));
        peer = System.getProperty("mcc.peer", peer);
        scenario = System.getProperty("mcc.scenario", scenario);
        server = System.getProperty("mcc.server");
        expectedPeers = List.of(System.getProperty("mcc.expectedPeers", peer).split(","));
        targetChunks = integer("mcc.targetChunks", targetChunks);
        minimumRadius = integer("mcc.minimumRadius", minimumRadius);
        maximumStallTicks = integer("mcc.maximumStallTicks", maximumStallTicks);
        maximumStreamTicks = integer("mcc.maximumStreamTicks", maximumStreamTicks);
        maximumTerrainTicks = integer("mcc.maximumTerrainTicks", maximumTerrainTicks);
        minimumSoakTicks = integer("mcc.minimumSoakTicks", minimumSoakTicks);
        timeoutTicks = integer("mcc.timeoutTicks", timeoutTicks);
        connectTick = integer("mcc.connectTick", connectTick);
        maximumCaptureBytes = Long.parseLong(System.getProperty("mcc.captureBytes", Long.toString(maximumCaptureBytes)));
        try {
            Files.createDirectories(eventsPath.getParent());
            Files.createDirectories(artifacts.resolve("screenshots"));
            events = Files.newBufferedWriter(eventsPath, StandardCharsets.UTF_8);
            enabled = true;
            event("probe_started", "scenario", scenario);
        } catch (IOException error) {
            throw new IllegalStateException("cannot initialize e2e probe", error);
        }
    }
    public synchronized void inboundRaw(byte[] bytes) {
        if (playTick < 0 && scenario.startsWith("auth-") && bytes.length > 1 && bytes[0] == 1)
            encryptionRequested = true;
        if (scenario.equals("fatal-storage") && bytes.length > 1 && bytes[0] == 0x1c &&
            new String(bytes, StandardCharsets.UTF_8).contains("Server stopped after an internal error. Please reconnect later."))
            fatalReasonReceived = true;
        record("clientbound", bytes);
    }
    public synchronized void outboundRaw(byte[] bytes) { record("serverbound", bytes); }
    public synchronized void chunkData(int x, int z, int skySetCount, int blockSetCount, int skyArrays, int blockArrays) {
        if (observedChunkPackets++ >= 64) return;
        event("chunk_data", "x", x, "z", z, "sky_set_count", skySetCount, "block_set_count", blockSetCount,
            "sky_arrays", skyArrays, "block_arrays", blockArrays);
    }
    public synchronized void chunkBatchStart() {
        if (observedChunkBoundaries++ < 64) event("chunk_batch_start");
    }
    public synchronized void chunkBatchFinished(int size) {
        if (observedChunkBoundaries++ < 64) event("chunk_batch_finished", "size", size);
    }
    public synchronized void chunkBatchAcknowledged(float desiredChunksPerTick) {
        if (observedChunkBoundaries++ < 64) event("chunk_batch_ack", "desired", desiredChunksPerTick);
    }
    public synchronized void playerLoadedSent() {
        if (observedReadinessEvents++ < 16) event("player_loaded_sent");
    }
    public synchronized void gameJoin() {
        if (observedReadinessEvents++ < 16) event("game_join");
    }
    public synchronized void gameStateChange(int reason, float value) {
        if (observedReadinessEvents++ < 16) event("game_state_change", "reason", reason, "value", value);
    }
    public void configurationStarted() { protocolPhase = "configuration"; }
    public void playStarted() { protocolPhase = "play"; }
    public void disconnected() { protocolPhase = "disconnected"; }
    public synchronized void advance(MinecraftClient client) {
        if (!enabled || written) return;
        client.options.pauseOnLostFocus = false;
        tick++;
        if (completed && resultPublished && tick >= stopTick) {
            client.scheduleStop();
            return;
        }
        if (completed) return;
        if (!connectionAttempted && server != null && tick >= connectTick && client.getOverlay() == null) {
            connectionAttempted = true;
            connectNanos = System.nanoTime();
            event("connect", "server", server);
            ConnectScreen.connect(new TitleScreen(), client, ServerAddress.parse(server),
                new ServerInfo("Lightning Rod E2E", server, ServerInfo.ServerType.OTHER), false,
                null);
        }
        String phase = protocolPhase;
        String screen = client.currentScreen == null ? "none" : client.currentScreen.getClass().getSimpleName();
        if (!phase.equals(lastPhase)) {
            event("phase", "value", phase);
            lastPhase = phase;
            if (phase.equals("configuration") && playTick >= 0) {
                sawConfiguration = true;
                screenshot(client, "configuration");
                if (client.currentScreen instanceof HandledScreen<?>) fail(client, "inventory_survived_configuration");
                if (((BossBarHudAccessor) client.inGameHud.getBossBarHud()).lightningRod$bossBars().size() != 0)
                    fail(client, "bossbar_survived_configuration");
            }
        }
        if (!screen.equals(lastScreen)) {
            String title = client.currentScreen == null ? "" : client.currentScreen.getTitle().getString();
            event("screen", "value", screen, "title", title);
            lastScreen = screen;
            if (client.currentScreen instanceof DisconnectedScreen && connectionAttempted) {
                if (scenario.equals("fatal-storage") && playTick >= 0 && terrainTick >= 0 && fatalReasonReceived)
                    pass(client, "fatal_disconnect_received");
                else if ((scenario.equals("auth-reject") && System.nanoTime() - connectNanos < 5_000_000_000L ||
                          scenario.equals("auth-timeout") && System.nanoTime() - connectNanos >= 25_000_000_000L && System.nanoTime() - connectNanos <= 35_000_000_000L) && playTick < 0 && encryptionRequested)
                    pass(client, "authentication_denied_before_play");
                else
                    fail(client, "disconnected: " + title);
            }
        }
        if (phase.equals("play")) {
            if (playTick < 0 || sawConfiguration && tick > reloadTick && lastLoaded < 0) {
                playTick = tick;
                playNanos = System.nanoTime();
                screenshot(client, sawConfiguration ? "play_after_reload" : "first_play");
            }
            int loaded = client.world.getChunkManager().getLoadedChunkCount();
            if (loaded > 0 && firstChunkTick < 0) {
                firstChunkTick = tick;
                firstChunkNanos = System.nanoTime();
            }
            if (loaded > 0 && terrainTick < 0 && client.currentScreen == null) {
                terrainTick = tick;
                terrainNanos = System.nanoTime();
            }
            if (terrainTick >= 0 && tick == terrainTick + 2) screenshot(client, "first_terrain");
            int missing = missingChunks(client, minimumRadius);
            int bossBars = ((BossBarHudAccessor) client.inGameHud.getBossBarHud()).lightningRod$bossBars().size();
            maximumBossBars = Math.max(maximumBossBars, bossBars);
            BlockPos position = client.player.getBlockPos();
            int top = client.world.getTopY(Heightmap.Type.WORLD_SURFACE, position.getX(), position.getZ()) + 1;
            int sky = client.world.getLightLevel(LightType.SKY, new BlockPos(position.getX(), top, position.getZ()));
            if (loaded != lastLoaded || missing != lastMissing || tick % 20 == 0) {
                event("world", "loaded", loaded, "missing", missing, "sky", sky, "bossbars", bossBars,
                    "x", position.getX(), "y", position.getY(), "z", position.getZ());
            }
            if (loaded > lastLoaded) lastProgressTick = tick;
            lastLoaded = loaded;
            lastMissing = missing;
            if (scenario.startsWith("chunks") || scenario.equals("steady") || scenario.equals("auth-success")) {
                if (scenario.equals("auth-success") && !encryptionRequested) fail(client, "authentication_was_bypassed");
                if (loaded >= targetChunks && missing == 0 && terrainTick >= 0) {
                    if (targetTick < 0) {
                        targetTick = tick;
                        targetNanos = System.nanoTime();
                        targetLoaded = loaded;
                        event("chunk_target_reached", "loaded", loaded);
                        if (maximumStreamTicks > 0 && targetNanos - firstChunkNanos > maximumStreamTicks * 50_000_000L) {
                            if (scenario.equals("steady")) streamDeadlineMissed = true;
                            else fail(client, "chunk_stream_deadline_exceeded");
                        }
                    }
                    if (scenario.equals("steady")) {
                        if (Files.exists(artifacts.resolve("steady-measured"))) {
                            if (streamDeadlineMissed) fail(client, "chunk_stream_deadline_exceeded");
                            else pass(client, "chunk_target_stable");
                        }
                    } else if (tick - targetTick >= minimumSoakTicks) pass(client, "chunk_target_stable");
                }
                else if (terrainTick < 0 && playTick >= 0 && System.nanoTime() - playNanos > maximumTerrainTicks * 50_000_000L)
                    fail(client, "loading_terrain_deadline_exceeded");
                else if (maximumStreamTicks > 0 && firstChunkTick >= 0 && System.nanoTime() - firstChunkNanos > maximumStreamTicks * 50_000_000L) {
                    if (scenario.equals("steady")) streamDeadlineMissed = true;
                    else fail(client, "chunk_stream_deadline_exceeded");
                }
                else if (lastProgressTick >= 0 && tick - lastProgressTick > maximumStallTicks)
                    fail(client, "chunk_stream_stalled");
            } else if (scenario.equals("skyblock-chat")) {
                advanceChat(client, loaded);
            } else if (scenario.startsWith("reload")) {
                advanceReload(client, loaded, missing);
            }
        } else if (sawConfiguration) {
            lastLoaded = -1;
            lastMissing = -1;
        }
        if (!completed && tick >= timeoutTicks) fail(client, "timeout");
    }
    private void record(String direction, byte[] bytes) {
        if (!enabled || written || output == null || capturedBytes + bytes.length > maximumCaptureBytes) return;
        capturedBytes += bytes.length;
        packets.add("packet " + tick + " " + direction + " " + peer + " " + HexFormat.of().formatHex(bytes));
    }
    public synchronized void write(MinecraftClient client) {
        if (!enabled || written) return;
        written = true;
        try {
            if (!resultPublished) {
                result(false, "client_stopped_before_visual_result");
                resultPublished = true;
            }
            if (output != null) {
                if (output.getParent() != null) Files.createDirectories(output.getParent());
                List<String> document = new ArrayList<>();
                document.add("mcc-capture-v1");
                document.add("minecraft 1.21.8");
                if (client.world != null) client.world.getPlayers().forEach(player -> document.add("identity " + player.getGameProfile().getName() + " " + player.getId()));
                document.addAll(packets);
                Files.writeString(output, String.join("\n", document) + "\n", StandardCharsets.UTF_8);
            }
            events.close();
        } catch (IOException error) { throw new IllegalStateException("cannot write e2e artifacts", error); }
    }

    public synchronized void chatReceived(String text) {
        if (!scenario.equals("skyblock-chat") || completed) return;
        for (String sender : expectedPeers) {
            String shortMessage = "<" + sender + "> e2e-chat:" + sender + ":short";
            String longMessage = "<" + sender + "> e2e-chat:" + sender + ":" + "\u2603".repeat(200);
            if (!text.equals(shortMessage) && !text.equals(longMessage)) continue;
            if (receivedChat.contains(text) || text.equals(longMessage) && !receivedChat.contains(shortMessage)) chatInvalid = true;
            receivedChat.add(text);
            event("chat_received", "sender", sender, "long", text.equals(longMessage));
        }
    }

    private void advanceChat(MinecraftClient client, int loaded) {
        if (terrainTick < 0 || loaded < 9) return;
        if (client.currentScreen != null) client.setScreen(null);
        if (chatWalkTick < 0) {
            chatWalkTick = tick;
            client.player.setYaw(peer.equals(expectedPeers.getFirst()) ? 90 : -90);
            client.player.setPitch(45);
            client.options.forwardKey.setPressed(true);
        }
        if (tick - chatWalkTick < 10) return;
        client.options.forwardKey.setPressed(false);
        if (!readyPublished) {
            marker(peer + ".chat-ready");
            readyPublished = true;
        }
        if (!chatSent && expectedPeers.stream().allMatch(value -> Files.exists(artifacts.resolve(value + ".chat-ready")))) {
            client.getNetworkHandler().sendChatMessage("e2e-chat:" + peer + ":short");
            client.getNetworkHandler().sendChatMessage("e2e-chat:" + peer + ":" + "\u2603".repeat(200));
            chatSent = true;
            event("chat_sent");
        }
        if (chatInvalid) fail(client, "chat_duplicate_or_reordered");
        else if (chatSent && receivedChat.size() == expectedPeers.size() * 2) {
            var roster = client.getNetworkHandler().getPlayerList();
            boolean rosterReady = roster.size() == expectedPeers.size()
                    && expectedPeers.stream().allMatch(name -> roster.stream()
                    .anyMatch(entry -> entry.getProfile().getName().equals(name)));
            if (!rosterReady) return;
            event("roster_received", "players", roster.size());
            client.getToastManager().clear();
            client.options.playerListKey.setPressed(true);
            pass(client, "shared_chat_and_roster_received_by_all_peers");
        }
    }

    private void advanceReload(MinecraftClient client, int loaded, int missing) {
        if (!openedInventory && loaded >= 9 && missing == 0) {
            openedInventory = true;
            inventoryTick = tick;
            UUID id = UUID.nameUUIDFromBytes(("lightning-rod-e2e-" + peer).getBytes(StandardCharsets.UTF_8));
            ((BossBarHudAccessor) client.inGameHud.getBossBarHud()).lightningRod$bossBars().put(id,
                new ClientBossBar(id, Text.literal("Reload boundary probe"), 1.0f,
                    BossBar.Color.BLUE, BossBar.Style.PROGRESS, false, false, false));
            client.setScreen(new InventoryScreen(client.player));
        }
        if (openedInventory && !readyPublished && tick - inventoryTick >= 5) {
            readyPublished = true;
            screenshot(client, "inventory_and_bossbar_before_reload");
            marker(peer + ".ready");
            event("reload_ready");
        }
        if (readyPublished && !reloadSent && Files.exists(artifacts.resolve("allow-reload"))) {
            reloadSent = true;
            reloadTick = tick;
            if (peer.equals(expectedPeers.getFirst())) {
                client.getNetworkHandler().sendChatCommand("reload");
                event("reload_sent");
            }
        }
        if (!reloadSent) return;
        if (scenario.equals("reload-failure")) {
            if (tick - reloadTick >= 300 && client.world != null && client.getNetworkHandler() != null)
                pass(client, "failed_reload_connection_survived");
            return;
        }
        if (sawConfiguration && tick - reloadTick > 2 && loaded >= 9 && missing == 0 && !(client.currentScreen instanceof HandledScreen<?>))
            pass(client, "reload_completed");
    }

    private int missingChunks(MinecraftClient client, int radius) {
        int centerX = client.player.getChunkPos().x;
        int centerZ = client.player.getChunkPos().z;
        int missing = 0;
        for (int z = centerZ - radius; z <= centerZ + radius; z++) {
            for (int x = centerX - radius; x <= centerX + radius; x++) {
                if (client.world.getChunkManager().getChunk(x, z, ChunkStatus.FULL, false) == null) missing++;
            }
        }
        return missing;
    }

    private void pass(MinecraftClient client, String reason) {
        if (completed) return;
        completed = true;
        stopTick = tick + 20;
        resultPassed = true;
        resultReason = reason;
        screenshot(client, "success");
    }

    private void fail(MinecraftClient client, String reason) {
        if (completed) return;
        completed = true;
        stopTick = tick + 20;
        resultPassed = false;
        resultReason = reason;
        screenshot(client, "failure");
    }

    private void result(boolean passed, String reason) {
        event("result", "passed", passed, "reason", reason, "ticks", tick, "play_tick", playTick,
            "first_chunk_tick", firstChunkTick, "terrain_tick", terrainTick, "loaded", lastLoaded, "missing", lastMissing,
            "maximum_bossbars", maximumBossBars, "captured_bytes", capturedBytes, "timing", "monotonic_wall");
        try {
            events.flush();
            Files.writeString(artifacts.resolve(peer + ".result"), (passed ? "PASS " : "FAIL ") + reason + "\n", StandardCharsets.UTF_8);
            long streamEndNanos = targetTick >= 0 ? targetNanos : System.nanoTime();
            long streamMilliseconds = firstChunkTick < 0 ? -1 : (streamEndNanos - firstChunkNanos) / 1_000_000;
            double streamSeconds = firstChunkTick < 0 ? 0.0 : (streamEndNanos - firstChunkNanos) / 1_000_000_000.0;
            double chunksPerSecond = streamSeconds <= 0.0 ? 0.0 : Math.max(0, targetTick >= 0 ? targetLoaded : lastLoaded) / streamSeconds;
            long loginMilliseconds = playTick < 0 ? -1 : (playNanos - connectNanos) / 1_000_000;
            long firstChunkMilliseconds = firstChunkTick < 0 ? -1 : (firstChunkNanos - connectNanos) / 1_000_000;
            long terrainMilliseconds = terrainTick < 0 ? -1 : (terrainNanos - connectNanos) / 1_000_000;
            String metrics = String.format(java.util.Locale.ROOT,
                "{\"scenario\":\"%s\",\"peer\":\"%s\",\"passed\":%s,\"reason\":\"%s\",\"client_ticks\":%d,\"play_tick\":%d,\"first_chunk_tick\":%d,\"terrain_tick\":%d,\"login_ms\":%d,\"first_chunk_ms\":%d,\"terrain_ms\":%d,\"stream_ms\":%d,\"loaded_chunks\":%d,\"missing_inner_chunks\":%d,\"chunks_per_second\":%.3f,\"maximum_bossbars\":%d,\"captured_bytes\":%d}\n",
                escape(scenario), escape(peer), passed, escape(reason), tick, playTick, firstChunkTick, terrainTick,
                loginMilliseconds, firstChunkMilliseconds, terrainMilliseconds, streamMilliseconds, lastLoaded, lastMissing, chunksPerSecond,
                maximumBossBars, capturedBytes);
            Files.writeString(artifacts.resolve(peer + ".metrics.json"), metrics, StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e result", error);
        }
    }

    private void screenshot(MinecraftClient client, String name) {
        pendingScreenshots.add(name);
    }

    public synchronized void rendered(MinecraftClient client) {
        if (!enabled || written || client.getFramebuffer() == null ||
            client.getOverlay() != null && (!completed || resultPassed)) return;
        for (String name : pendingScreenshots) {
            boolean terminal = name.equals("success") || name.equals("failure");
            String filename = peer + "-" + tick + "-" + name + ".png";
            ScreenshotRecorder.saveScreenshot(artifacts.toFile(), filename, client.getFramebuffer(), 1, message -> {
                synchronized (this) {
                    event("screenshot", "name", name, "message", message.getString());
                    if (terminal && !resultPublished) {
                        Path image = artifacts.resolve("screenshots").resolve(filename);
                        boolean saved;
                        try {
                            saved = Files.isRegularFile(image) && Files.size(image) > 0;
                        } catch (IOException error) {
                            saved = false;
                        }
                        result(resultPassed && saved, saved ? resultReason : "terminal_screenshot_missing");
                        resultPublished = true;
                    }
                }
            });
        }
        pendingScreenshots.clear();
    }

    private void marker(String name) {
        try {
            Files.writeString(artifacts.resolve(name), "ready\n", StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e marker", error);
        }
    }

    private void event(String name, Object... fields) {
        if (events == null) return;
        try {
            StringBuilder line = new StringBuilder("{\"tick\":").append(tick)
                .append(",\"peer\":\"").append(escape(peer)).append("\",\"event\":\"").append(escape(name)).append('"');
            for (int index = 0; index < fields.length; index += 2) {
                line.append(",\"").append(escape(fields[index].toString())).append("\":");
                Object value = fields[index + 1];
                if (value instanceof Number || value instanceof Boolean) line.append(value);
                else line.append('"').append(escape(value.toString())).append('"');
            }
            events.write(line.append("}\n").toString());
            events.flush();
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e event", error);
        }
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }

    private static Path optionalPath(String key) {
        String value = System.getProperty(key);
        return value == null || value.isBlank() ? null : Path.of(value);
    }

    private static int integer(String key, int fallback) {
        return Integer.parseInt(System.getProperty(key, Integer.toString(fallback)));
    }
}
