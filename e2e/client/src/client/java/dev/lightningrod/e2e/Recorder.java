package dev.lightningrod.e2e;

import java.io.IOException;
import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.ConnectScreen;
import net.minecraft.client.gui.screens.DisconnectedScreen;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.resolver.ServerAddress;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.levelgen.Heightmap;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import io.netty.buffer.ByteBuf;

public final class Recorder {
    Fixture fixture;
    boolean functionalPassed;
    String fixtureReason;

    public void reconfigurationEncoded() { if (fixture != null) fixture.reconfigurationEncoded(); }
    public void encryptionResponseEncoded(ByteBuf encoded) { if (fixture != null) fixture.encryptionResponseEncoded(encoded); }
    static final Recorder INSTANCE = new Recorder();
    static final class Capture {
        private final String name;
        private final boolean terminal;
        private final boolean checkpoint;
        private boolean renderReady;
        private boolean finished;
        private boolean saved;

        Capture(String name, boolean terminal, boolean checkpoint) {
            this.name = name;
            this.terminal = terminal;
            this.checkpoint = checkpoint;
        }
        String name() { return name; }
        boolean terminal() { return terminal; }
        boolean done() { return finished && saved; }
    }
    final List<Capture> pendingScreenshots = new ArrayList<>();
    private Capture terminalCapture;
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
    private long targetTick = -1;
    private long streamStartTick = -1;
    private long streamStartNanos;
    long connectNanos;
    long playNanos;
    long firstChunkNanos;
    long terrainNanos;
    private long targetNanos;
    private int targetLoaded;
    int targetChunks;
    int minimumRadius;
    int minimumSoakTicks = 0;
    int timeoutTicks = 2400;
    int connectTick = 40;
    boolean ready;
    boolean started;
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
        minimumSoakTicks = integer("mcc.minimumSoakTicks", minimumSoakTicks);
        timeoutTicks = integer("mcc.timeoutTicks", timeoutTicks);
        connectTick = integer("mcc.connectTick", connectTick);
        fixture = Fixture.create(this, scenario);
        int distance = fixture.renderDistance();
        minimumRadius = integer("mcc.minimumRadius", distance);
        targetChunks = integer("mcc.targetChunks", (2 * distance + 1) * (2 * distance + 1));
        try {
            Files.createDirectories(eventsPath.getParent());
            Files.createDirectories(artifacts.resolve("screenshots"));
            events = Files.newBufferedWriter(eventsPath);
            enabled = true;
            event("probe_started", "scenario", scenario, "version", ClientCompatibility.version());
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
    public synchronized void advance(Minecraft client) {
        if (!enabled || written) return;
        advanceFixture(client);
        if (started && !completed && tick >= timeoutTicks) fail("timeout");
    }

    private void advanceFixture(Minecraft client) {
        if (!enabled || written) return;
        client.options.pauseOnLostFocus = false;
        if (!started) {
            if (GuiApi.overlay(client) != null) return;
            if (!ready) {
                marker(peer + ".ready");
                ready = true;
            }
            if (!Files.exists(artifacts.resolve("clients.start"))) return;
            started = true;
        }
        tick++;
        if (completed && resultPublished && tick >= stopTick) {
            client.stop();
            return;
        }
        if (completed) return;
        if (!connectionAttempted && server != null && tick >= connectTick && GuiApi.overlay(client) == null && fixture.canConnect()) {
            if (!ClientCompatibility.version().equals(System.getProperty("mcc.version"))) {
                fail("unexpected_client_version");
                return;
            }
            client.options.renderDistance().set(fixture.renderDistance());
            connectionAttempted = true;
            connectNanos = System.nanoTime();
            event("connect", "server", server);
            ConnectScreen.startConnecting(new TitleScreen(), client, ServerAddress.parseString(server),
                new ServerData("Lightning Rod E2E", server, ServerData.Type.OTHER), false,
                null);
        }
        String phase = protocolPhase;
        fixture.poll(client);
        String screen = GuiApi.screen(client) == null ? "none" : GuiApi.screen(client).getClass().getSimpleName();
        if (!phase.equals(lastPhase)) {
            event("phase", "value", phase);
            lastPhase = phase;
        }
        if (!screen.equals(lastScreen)) {
            String title = GuiApi.screen(client) == null ? "" : GuiApi.screen(client).getTitle().getString();
            event("screen", "value", screen, "title", title);
            lastScreen = screen;
            if (GuiApi.screen(client) instanceof DisconnectedScreen && connectionAttempted) {
                fixture.disconnected(client, title);
            }
        }
        if (phase.equals("play") && client.level != null && client.player != null) {
            if (fixture.encrypted()) {
                var channel = ((ClientConnectionAccessor) client.getConnection().getConnection()).lightningRod$channel();
                if (channel.pipeline().get("decrypt") == null || channel.pipeline().get("encrypt") == null) {
                    fail("encryption_was_bypassed");
                    return;
                }
            }
            fixture.connected(client);
            if (playTick < 0) {
                playTick = tick;
                playNanos = System.nanoTime();
                screenshot("first_play");
            }
            int loaded = client.level.getChunkSource().getLoadedChunksCount();
            if (loaded > 0 && firstChunkTick < 0) {
                firstChunkTick = tick;
                firstChunkNanos = System.nanoTime();
                if (streamStartTick < 0) restartStream();
            }
            if (loaded > 0 && terrainTick < 0 && GuiApi.screen(client) == null) {
                terrainTick = tick;
                terrainNanos = System.nanoTime();
            }
            if (terrainTick >= 0 && tick == terrainTick + 2) screenshot("first_terrain");
            if (!fixture.prepare(client)) return;
            int missing = Fixture.missingChunks(client, minimumRadius);
            int bossBars = ((BossBarHudAccessor) GuiApi.bossBars(client)).lightningRod$bossBars().size();
            maximumBossBars = Math.max(maximumBossBars, bossBars);
            BlockPos position = client.player.blockPosition();
            int top = client.level.getHeight(Heightmap.Types.WORLD_SURFACE, position.getX(), position.getZ()) + 1;
            int sky = client.level.getBrightness(LightLayer.SKY, new BlockPos(position.getX(), top, position.getZ()));
            if (loaded != lastLoaded || missing != lastMissing || tick % 20 == 0) {
                event("world", "loaded", loaded, "missing", missing, "sky", sky, "bossbars", bossBars,
                    "x", position.getX(), "y", position.getY(), "z", position.getZ(),
                    "chunk_packets", observedChunkPackets, "batch_events", observedChunkBoundaries,
                    "elapsed_ms", (System.nanoTime() - connectNanos) / 1_000_000);
            }
            if (targetTick < 0 && tick % 100 == 0 && progressScreenshots < 6)
                screenshot("stream_progress_" + ++progressScreenshots);
            lastLoaded = loaded;
            lastMissing = missing;
            fixture.tick(client, loaded, missing);
        }
        if (!completed && tick >= timeoutTicks) fail("timeout");
    }

    public synchronized void packetFailed(byte[] bytes, Exception error) {
        if (!enabled || written) return;
        try {
            var packet = artifacts.resolve(peer + "-failed-packet.bin");
            if (Files.exists(packet)) return;
            Files.write(packet, bytes);
            Artifacts.publish(artifacts.resolve(peer + "-failed-packet.txt"), error.toString());
            error.printStackTrace();
        } catch (IOException failure) {
            error.addSuppressed(failure);
        }
    }

    public synchronized void write() {
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
        if (!enabled || resultPublished) return;
        event("server_message", "text", text);
        fixture.chat(text);
    }

    void pass(String reason) {
        if (completed) return;
        completed = true;
        stopTick = tick + 20;
        functionalPassed = true;
        fixtureReason = reason;
        resultPassed = true;
        resultReason = reason;
        terminalCapture = new Capture("success", true, false);
        pendingScreenshots.add(terminalCapture);
    }

    void fail(String reason) {
        if (resultPublished || completed && !resultPassed) return;
        completed = true;
        stopTick = tick + 20;
        functionalPassed = false;
        resultPassed = false;
        resultReason = reason;
        fixtureReason = reason;
        pendingScreenshots.removeIf(Capture::terminal);
        terminalCapture = new Capture("failure", true, false);
        pendingScreenshots.add(terminalCapture);
    }

    void result(boolean passed, String reason) {
        event("result", "passed", passed, "reason", reason, "ticks", tick, "play_tick", playTick,
            "first_chunk_tick", firstChunkTick, "terrain_tick", terrainTick, "loaded", lastLoaded, "missing", lastMissing,
            "maximum_bossbars", maximumBossBars, "timing", "monotonic_wall");
        try {
            events.flush();
            long streamEndNanos = targetTick >= 0 ? targetNanos : System.nanoTime();
            long streamMilliseconds = streamStartTick < 0 ? -1 : (streamEndNanos - streamStartNanos) / 1_000_000;
            double streamSeconds = streamStartTick < 0 ? 0.0 : (streamEndNanos - streamStartNanos) / 1_000_000_000.0;
            double chunksPerSecond = streamSeconds <= 0.0 ? 0.0 : Math.max(0, targetTick >= 0 ? targetLoaded : lastLoaded) / streamSeconds;
            long loginMilliseconds = playTick < 0 ? -1 : (playNanos - connectNanos) / 1_000_000;
            long firstChunkMilliseconds = firstChunkTick < 0 ? -1 : (firstChunkNanos - connectNanos) / 1_000_000;
            long terrainMilliseconds = terrainTick < 0 ? -1 : (terrainNanos - connectNanos) / 1_000_000;
            String metrics = String.format(java.util.Locale.ROOT,
                "{\"scenario\":\"%s\",\"peer\":\"%s\",\"passed\":%s,\"reason\":\"%s\",\"client_ticks\":%d,\"play_tick\":%d,\"first_chunk_tick\":%d,\"terrain_tick\":%d,\"login_ms\":%d,\"first_chunk_ms\":%d,\"terrain_ms\":%d,\"stream_ms\":%d,\"loaded_chunks\":%d,\"missing_inner_chunks\":%d,\"chunks_per_second\":%.3f,\"maximum_bossbars\":%d}\n",
                escape(scenario), escape(peer), passed, escape(reason), tick, playTick, firstChunkTick, terrainTick,
                loginMilliseconds, firstChunkMilliseconds, terrainMilliseconds, streamMilliseconds, lastLoaded, lastMissing, chunksPerSecond,
                maximumBossBars);
            metrics = metrics.stripTrailing();
            metrics = metrics.substring(0, metrics.length() - 1)
                + ",\"stream_start_tick\":" + streamStartTick
                + ",\"stream_target_tick\":" + targetTick
                + ",\"functional_passed\":" + functionalPassed
                + ",\"fixture_reason\":\"" + escape(fixtureReason == null ? reason : fixtureReason) + "\""
                + "}\n";
            Artifacts.publish(artifacts.resolve(peer + ".metrics.json"), metrics);
            Artifacts.publish(artifacts.resolve(peer + ".result"), (passed ? "PASS " : "FAIL ") + reason + "\n");
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e result", error);
        }
    }

    void restartStream() {
        streamStartTick = tick;
        streamStartNanos = System.nanoTime();
        targetTick = -1;
        targetNanos = 0;
        targetLoaded = 0;
        progressScreenshots = 0;
    }

    long streamTarget(int loaded) {
        if (streamStartTick < 0) throw new IllegalStateException("stream has not started");
        if (targetTick < 0) {
            targetTick = tick;
            targetNanos = System.nanoTime();
            targetLoaded = loaded;
            event("chunk_target_reached", "loaded", loaded);
        }
        return targetTick;
    }

    Capture screenshot(String name) {
        Capture capture = new Capture(name, false, false);
        pendingScreenshots.add(capture);
        return capture;
    }

    Capture checkpoint(String name) {
        Capture capture = new Capture(name, false, true);
        pendingScreenshots.add(capture);
        return capture;
    }

    public synchronized void rendered(Minecraft client) {
        if (!enabled || written || pendingScreenshots.isEmpty() || GuiApi.target(client) == null ||
            GuiApi.overlay(client) != null && (!completed || resultPassed)) return;
        List<Capture> captures = new ArrayList<>(pendingScreenshots);
        for (Capture capture : captures) {
            if (capture.checkpoint || capture.terminal && resultPassed && client.level != null) {
                boolean ready = client.level == null && GuiApi.screen(client) instanceof DisconnectedScreen
                    || client.player != null && client.level != null
                        && Fixture.missingChunks(client, minimumRadius) == 0
                        && TerrainApi.ready(client);
                boolean rendered = capture.renderReady;
                capture.renderReady = ready;
                // A ready renderer at frame end may have uploaded terrain after drawing this frame.
                if (!ready || !rendered) continue;
            }
            pendingScreenshots.remove(capture);
            String filename = peer + "-" + tick + "-" + capture.name() + ".png";
            ClientCompatibility.screenshot(artifacts.toFile(), filename, GuiApi.target(client), message -> {
                synchronized (this) {
                    event("screenshot", "name", capture.name(), "message", message.getString());
                    Path image = artifacts.resolve("screenshots").resolve(filename);
                    boolean saved;
                    try {
                        saved = Files.isRegularFile(image) && Files.size(image) > 0;
                    } catch (IOException error) {
                        saved = false;
                    }
                    captureFinished(capture, saved);
                }
            });
        }
    }

    void captureFinished(Capture capture, boolean saved) {
        if (capture.finished) return;
        capture.saved = saved;
        capture.finished = true;
        if (capture.checkpoint && !saved) fail("checkpoint_screenshot_missing_" + capture.name());
        if (!saved) event("screenshot_missing", "name", capture.name());
        if (!capture.terminal() || capture != terminalCapture || resultPublished) return;
        result(resultPassed && saved, !saved && resultPassed ? "terminal_screenshot_missing" : resultReason);
        resultPublished = true;
    }

    public synchronized void blockBreaking(BlockPos position, int stage) { if (fixture != null) fixture.blockBreaking(position, stage); }
    public synchronized void inventorySynced(int containerId) {
        if (containerId == 0 && fixture != null) fixture.inventorySynced(Minecraft.getInstance());
    }

    void marker(String name) {
        try {
            Artifacts.publish(artifacts.resolve(name), "ready\n");
        } catch (IOException error) {
            throw new IllegalStateException("cannot write e2e marker", error);
        }
    }

    void event(String name, Object... fields) {
        if (events == null) return;
        try {
            StringBuilder line = new StringBuilder("{\"tick\":").append(tick)
                .append(",\"unix_ms\":").append(System.currentTimeMillis())
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
