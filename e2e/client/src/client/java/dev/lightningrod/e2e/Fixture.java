package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import io.netty.buffer.ByteBuf;
import net.minecraft.core.BlockPos;
import net.minecraft.util.Mth;
import net.minecraft.world.level.chunk.status.ChunkStatus;

abstract class Fixture {
    final Recorder r;
    final TestClient client;

    Fixture(Recorder recorder) { r = recorder; client = new TestClient(recorder); }

    static Fixture create(Recorder r, String name) {
        return DiscoveredTests.create(r, name);
    }

    void poll(Minecraft game) {}
    void connected(Minecraft game) {}
    boolean encrypted() { return false; }
    boolean canConnect() { return true; }
    int renderDistance() { return 2; }
    void disconnected(Minecraft game, String title) { client.fail("disconnected: " + title); }
    boolean prepare(Minecraft game) { return true; }
    abstract void tick(Minecraft game, int loaded, int missing);
    void message(String text) {}
    void chat(String text) { r.receivedChat.add(text); }
    void chatAction(String text, String command, String hover) {}
    void blockBreaking(BlockPos position, int stage) {}
    void inventorySynced(Minecraft game) {}
    void reconfigurationEncoded() {}
    void encryptionResponseEncoded(ByteBuf encoded) {}

    static boolean close(double actual, double expected, double tolerance) {
        return Math.abs(actual - expected) <= tolerance;
    }

    static boolean angleClose(float actual, float expected) {
        return Math.abs(Mth.wrapDegrees(actual - expected)) <= 2.0f;
    }

    static int missingChunks(Minecraft client, int radius) {
        int centerX = (client.player.getBlockX() >> 4);
        int centerZ = (client.player.getBlockZ() >> 4);
        int missing = 0;
        for (int z = centerZ - radius; z <= centerZ + radius; z++) {
            for (int x = centerX - radius; x <= centerX + radius; x++) {
                if (client.level.getChunkSource().getChunk(x, z, ChunkStatus.FULL, false) == null) missing++;
            }
        }
        return missing;
    }
}
