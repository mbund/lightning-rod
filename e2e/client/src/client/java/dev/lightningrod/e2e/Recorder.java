package dev.lightningrod.e2e;

import java.io.IOException;
import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.screen.TitleScreen;
import net.minecraft.client.gui.screen.DisconnectedScreen;
import net.minecraft.client.gui.screen.multiplayer.ConnectScreen;
import net.minecraft.client.network.ServerAddress;
import net.minecraft.client.network.ServerInfo;
import net.minecraft.client.util.ScreenshotRecorder;
import net.minecraft.util.math.BlockPos;
import net.minecraft.util.math.MathHelper;
import net.minecraft.world.Heightmap;
import net.minecraft.world.LightType;
import net.minecraft.world.chunk.ChunkStatus;

public final class Recorder {
    Fixture fixture;

    public void reconfigurationEncoded() { if (fixture != null) fixture.reconfigurationEncoded(); }
    static final Recorder INSTANCE = new Recorder();
    final List<String> pendingScreenshots = new ArrayList<>();
    boolean resultPublished;
    boolean resultPassed;
    String resultReason;
    Path eventsPath;
    Path artifacts;
    BufferedWriter events;
    String peer = "client";
    String scenario = "chunks";
    String server;
    List<String> expectedPeers = List.of("client");
    long tick;
    long playTick = -1;
    long firstChunkTick = -1;
    long terrainTick = -1;
    long targetTick = -1;
    long connectNanos;
    long playNanos;
    long firstChunkNanos;
    long terrainNanos;
    long targetNanos;
    int targetLoaded;
    long lastProgressTick = -1;
    int targetChunks = 4225;
    int minimumRadius = 32;
    int maximumStallTicks = 100;
    int maximumStreamTicks = 100;
    int maximumTerrainTicks = 40;
    int minimumSoakTicks = 0;
    int timeoutTicks = 2400;
    int connectTick = 40;
    int lastLoaded = -1;
    int lastMissing = -1;
    int maximumBossBars;
    String lastPhase = "starting";
    volatile String protocolPhase = "disconnected";
    String lastScreen = "";
    boolean completed;
    int joins;
    final List<String> receivedChat = new ArrayList<>();
    boolean connectionAttempted;
    boolean enabled;
    boolean written;
    long stopTick = -1;
    int observedChunkPackets;
    int observedChunkBoundaries;
    int observedReadinessEvents;
    int progressScreenshots;
    public static Recorder instance() { return INSTANCE; }
    public void configure() {
        String value = System.getProperty("mcc.events");
        if (value == null || value.isBlank()) return;
        eventsPath = Path.of(value);
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
        fixture = Fixture.create(this, scenario);
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
    public synchronized void chunkData(int x, int z, int skySetCount, int blockSetCount, int skyArrays, int blockArrays) {
        if (observedChunkPackets++ >= 64 && observedChunkPackets % 64 != 0) return;
        event("chunk_data", "x", x, "z", z, "sky_set_count", skySetCount, "block_set_count", blockSetCount,
            "sky_arrays", skyArrays, "block_arrays", blockArrays);
    }
    public synchronized void chunkBatchStart() {
        if (observedChunkBoundaries++ < 64 || observedChunkBoundaries % 64 == 0) event("chunk_batch_start");
    }
    public synchronized void chunkBatchFinished(int size) {
        if (observedChunkBoundaries++ < 64 || observedChunkBoundaries % 64 == 0) event("chunk_batch_finished", "size", size);
    }
    public synchronized void chunkBatchAcknowledged(float desiredChunksPerTick) {
        if (observedChunkBoundaries++ < 64 || observedChunkBoundaries % 64 == 0) event("chunk_batch_ack", "desired", desiredChunksPerTick);
    }
    public synchronized void playerLoadedSent() {
        if (observedReadinessEvents++ < 16) event("player_loaded_sent");
    }
    public synchronized void gameJoin() {
        joins++;
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
            client.options.getViewDistance().setValue(32);
            connectionAttempted = true;
            connectNanos = System.nanoTime();
            event("connect", "server", server);
            ConnectScreen.connect(new TitleScreen(), client, ServerAddress.parse(server),
                new ServerInfo("Lightning Rod E2E", server, ServerInfo.ServerType.OTHER), false,
                null);
        }
        String phase = protocolPhase;
        fixture.poll(client);
        String screen = client.currentScreen == null ? "none" : client.currentScreen.getClass().getSimpleName();
        if (!phase.equals(lastPhase)) {
            event("phase", "value", phase);
            lastPhase = phase;
        }
        if (!screen.equals(lastScreen)) {
            String title = client.currentScreen == null ? "" : client.currentScreen.getTitle().getString();
            event("screen", "value", screen, "title", title);
            lastScreen = screen;
            if (client.currentScreen instanceof DisconnectedScreen && connectionAttempted) {
                fixture.disconnected(client, title);
            }
        }
        if (phase.equals("play") && client.world != null && client.player != null) {
            if (fixture.encrypted()) {
                var channel = ((ClientConnectionAccessor) client.getNetworkHandler().getConnection()).lightningRod$channel();
                if (channel.pipeline().get("decrypt") == null || channel.pipeline().get("encrypt") == null) {
                    fail(client, "encryption_was_bypassed");
                    return;
                }
            }
            fixture.connected(client);
            if (playTick < 0) {
                playTick = tick;
                playNanos = System.nanoTime();
                screenshot(client, "first_play");
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
            if (!fixture.prepare(client)) return;
            int missing = missingChunks(client, minimumRadius);
            int bossBars = ((BossBarHudAccessor) client.inGameHud.getBossBarHud()).lightningRod$bossBars().size();
            maximumBossBars = Math.max(maximumBossBars, bossBars);
            BlockPos position = client.player.getBlockPos();
            int top = client.world.getTopY(Heightmap.Type.WORLD_SURFACE, position.getX(), position.getZ()) + 1;
            int sky = client.world.getLightLevel(LightType.SKY, new BlockPos(position.getX(), top, position.getZ()));
            if (loaded != lastLoaded || missing != lastMissing || tick % 20 == 0) {
                event("world", "loaded", loaded, "missing", missing, "sky", sky, "bossbars", bossBars,
                    "x", position.getX(), "y", position.getY(), "z", position.getZ(),
                    "chunk_packets", observedChunkPackets, "batch_events", observedChunkBoundaries,
                    "elapsed_ms", (System.nanoTime() - connectNanos) / 1_000_000);
            }
            if (targetTick < 0 && tick % 100 == 0 && progressScreenshots < 6)
                screenshot(client, "stream_progress_" + ++progressScreenshots);
            if (loaded > lastLoaded) lastProgressTick = tick;
            lastLoaded = loaded;
            lastMissing = missing;
            fixture.tick(client, loaded, missing);
        }
        if (!completed && tick >= timeoutTicks) fail(client, "timeout");
    }

    static boolean close(double actual, double expected, double tolerance) {
        return Math.abs(actual - expected) <= tolerance;
    }

    static boolean angleClose(float actual, float expected) {
        return Math.abs(MathHelper.wrapDegrees(actual - expected)) <= 2.0f;
    }
    public synchronized void write(MinecraftClient client) {
        if (!enabled || written) return;
        written = true;
        try {
            if (!resultPublished) {
                result(false, "client_stopped_before_visual_result");
                resultPublished = true;
            }
            events.close();
        } catch (IOException error) { throw new IllegalStateException("cannot write e2e artifacts", error); }
    }

public synchronized void chatReceived(String text) {
        if (completed) return;
        event("server_message", "text", text);
        fixture.chat(text);
    }

    int missingChunks(MinecraftClient client, int radius) {
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

    void pass(MinecraftClient client, String reason) {
        if (completed) return;
        completed = true;
        stopTick = tick + 20;
        resultPassed = true;
        resultReason = reason;
        screenshot(client, "success");
    }

    void fail(MinecraftClient client, String reason) {
        if (completed) return;
        completed = true;
        stopTick = tick + 20;
        resultPassed = false;
        resultReason = reason;
        screenshot(client, "failure");
    }

    void result(boolean passed, String reason) {
        event("result", "passed", passed, "reason", reason, "ticks", tick, "play_tick", playTick,
            "first_chunk_tick", firstChunkTick, "terrain_tick", terrainTick, "loaded", lastLoaded, "missing", lastMissing,
            "maximum_bossbars", maximumBossBars, "timing", "monotonic_wall");
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
                "{\"scenario\":\"%s\",\"peer\":\"%s\",\"passed\":%s,\"reason\":\"%s\",\"client_ticks\":%d,\"play_tick\":%d,\"first_chunk_tick\":%d,\"terrain_tick\":%d,\"login_ms\":%d,\"first_chunk_ms\":%d,\"terrain_ms\":%d,\"stream_ms\":%d,\"loaded_chunks\":%d,\"missing_inner_chunks\":%d,\"chunks_per_second\":%.3f,\"maximum_bossbars\":%d}\n",
                escape(scenario), escape(peer), passed, escape(reason), tick, playTick, firstChunkTick, terrainTick,
                loginMilliseconds, firstChunkMilliseconds, terrainMilliseconds, streamMilliseconds, lastLoaded, lastMissing, chunksPerSecond,
                maximumBossBars);
            Files.writeString(artifacts.resolve(peer + ".metrics.json"), metrics, StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e result", error);
        }
    }

    void screenshot(MinecraftClient client, String name) {
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

    public synchronized void blockBreaking(BlockPos position, int stage) { if (fixture != null) fixture.blockBreaking(position, stage); }

    void marker(String name) {
        try {
            Files.writeString(artifacts.resolve(name), "ready\n", StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e marker", error);
        }
    }

    void event(String name, Object... fields) {
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

    static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }

    static int integer(String key, int fallback) {
        return Integer.parseInt(System.getProperty(key, Integer.toString(fallback)));
    }
}
