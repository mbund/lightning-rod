package dev.mbund.lightningrod.conformance;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;

/** Records only externally visible network observations; it owns no gameplay. */
public final class RecorderClient implements ClientModInitializer {
    @Override public void onInitializeClient() {
        Recorder.instance().configure();
        ClientTickEvents.END_CLIENT_TICK.register(client -> Recorder.instance().advance());
        ClientLifecycleEvents.CLIENT_STOPPING.register(client -> Recorder.instance().write(client));
    }
}
