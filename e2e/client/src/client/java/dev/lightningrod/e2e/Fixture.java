package dev.lightningrod.e2e;

import net.minecraft.client.MinecraftClient;
import net.minecraft.util.math.BlockPos;

abstract class Fixture {
    final Recorder r;

    Fixture(Recorder recorder) { r = recorder; }

    static Fixture create(Recorder r, String name) {
        return DiscoveredTests.create(r, name);
    }

    void poll(MinecraftClient client) {}
    void connected(MinecraftClient client) {}
    boolean encrypted() { return false; }
    void disconnected(MinecraftClient client, String title) { r.fail(client, "disconnected: " + title); }
    boolean prepare(MinecraftClient client) { return true; }
    abstract void tick(MinecraftClient client, int loaded, int missing);
    void chat(String text) { r.receivedChat.add(text); }
    void blockBreaking(BlockPos position, int stage) {}
    void reconfigurationEncoded() {}
}
