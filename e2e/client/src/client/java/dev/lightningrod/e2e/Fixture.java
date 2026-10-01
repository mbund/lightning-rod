package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;

abstract class Fixture {
    final Recorder r;

    Fixture(Recorder recorder) { r = recorder; }

    static Fixture create(Recorder r, String name) {
        return DiscoveredTests.create(r, name);
    }

    void poll(Minecraft client) {}
    void connected(Minecraft client) {}
    boolean encrypted() { return false; }
    void disconnected(Minecraft client, String title) { r.fail(client, "disconnected: " + title); }
    boolean prepare(Minecraft client) { return true; }
    abstract void tick(Minecraft client, int loaded, int missing);
    void chat(String text) { r.receivedChat.add(text); }
    void blockBreaking(BlockPos position, int stage) {}
    void reconfigurationEncoded() {}
}
