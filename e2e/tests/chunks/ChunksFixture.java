package dev.lightningrod.e2e;

import java.io.IOException;
import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class ChunksFixture extends Fixture {
    private boolean relocated;
    private boolean readsPaused;
    private boolean readsResumed;
    private boolean streamDeadlineMissed;

    ChunksFixture(Recorder r) {
        super(r);
        if (r.scenario.endsWith("-multi") || r.scenario.equals("chunks-isolation")) r.maximumStreamTicks *= r.expectedPeers.size();
        if (r.scenario.startsWith("chunks-prepare")) r.maximumStreamTicks = 0;
    }
    @Override boolean encrypted() { return r.scenario.contains("encrypted"); }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (loaded >= r.targetChunks && missing == 0 && r.terrainTick >= 0) {
            if (r.scenario.equals("chunks-simulations-multi")) {
                if (client.level.players().size() != 1 || client.getConnection().getOnlinePlayers().size() != 1) {
                    r.fail(client, "simulation_players_leaked");
                    return;
                }
                var stack = client.player.getInventory().getItem(0);
                if (r.peer.equals("alice") ? !stack.is(net.minecraft.world.item.Items.BREAD) || stack.getCount() != 17 : !stack.isEmpty()) {
                    r.fail(client, "simulation_inventory_leaked");
                    return;
                }
            }
            if (r.targetTick < 0) {
                r.targetTick = r.tick;
                r.targetNanos = System.nanoTime();
                r.targetLoaded = loaded;
                r.event("chunk_target_reached", "loaded", loaded);
                if (r.maximumStreamTicks > 0 && r.targetNanos - r.firstChunkNanos > r.maximumStreamTicks * 50_000_000L) {
                    streamDeadlineMissed = true;
                }
            }
            if (r.tick - r.targetTick >= r.minimumSoakTicks) {
                if (streamDeadlineMissed) r.fail(client, "chunk_stream_deadline_exceeded");
                else r.pass(client, "chunk_target_stable");
            }
        }
        else if (r.terrainTick < 0 && r.playTick >= 0 && System.nanoTime() - r.playNanos > r.maximumTerrainTicks * 50_000_000L)
            r.fail(client, "loading_terrain_deadline_exceeded");
        else if (r.maximumStreamTicks > 0 && r.firstChunkTick >= 0 && System.nanoTime() - r.firstChunkNanos > r.maximumStreamTicks * 50_000_000L) {
            streamDeadlineMissed = true;
        }
        else if (r.lastProgressTick >= 0 && r.tick - r.lastProgressTick > r.maximumStallTicks)
            r.fail(client, "chunk_stream_stalled");

    }

    @Override public boolean prepare(Minecraft client) {
        if (r.scenario.startsWith("chunks-") && r.scenario.endsWith("-multi") || r.scenario.equals("chunks-isolation")) {
            if (r.terrainTick < 0) return false;
            if (!relocated) {
                if (r.scenario.startsWith("chunks-prepare") && r.missingChunks(client, r.minimumRadius) != 0) return false;
                try {
                    Files.writeString(r.artifacts.resolve(r.peer + ".ready"), "ready");
                    for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".ready"))) return false;
                } catch (IOException error) { throw new IllegalStateException(error); }
                double x = r.peer.equals("alice") ? -4095.5 : 4096.5;
                if (!client.player.getAbilities().mayfly) {
                    r.fail(client, "creative_flight_not_available");
                    return false;
                }
                client.player.getAbilities().flying = true;
                client.player.onUpdateAbilities();
                client.player.setPos(x, 65, x);
                client.player.setXRot(30);
                client.getConnection().send(new ServerboundMovePlayerPacket.Pos(x, 65, x, true, false));
                relocated = true;
                r.firstChunkTick = r.tick;
                r.firstChunkNanos = System.nanoTime();
                r.lastProgressTick = r.tick;
                r.lastLoaded = -1;
                r.event("stream_relocated", "x", x, "z", x);
                return false;
            }
            double expected = r.peer.equals("alice") ? -4095.5 : 4096.5;
            if (Math.abs(client.player.getX() - expected) > 1 || Math.abs(client.player.getZ() - expected) > 1) {
                r.fail(client, "independent_stream_position_changed");
                return false;
            }
            if (r.scenario.equals("chunks-isolation") && r.peer.equals("bob")) {
                var channel = ((ClientConnectionAccessor) client.getConnection().getConnection()).lightningRod$channel();
                if (!readsPaused) {
                    channel.config().setAutoRead(false);
                    readsPaused = true;
                    r.event("slow_reader_paused");
                }
                if (!readsResumed && Files.exists(r.artifacts.resolve("alice.result"))) {
                    channel.config().setAutoRead(true);
                    readsResumed = true;
                    r.firstChunkNanos = System.nanoTime();
                    r.firstChunkTick = r.tick;
                    r.lastProgressTick = r.tick;
                    r.event("slow_reader_resumed");
                }
                if (!readsResumed) return false;
            }
        }
        return true;
    }
}
