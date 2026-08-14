package dev.mbund.lightningrod.conformance;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;

public final class RecorderClient implements ClientModInitializer {
    @Override
    public void onInitializeClient() {
        Recorder.instance().configureFromSystemProperties();
        ClientTickEvents.START_CLIENT_TICK.register(Recorder.instance()::startTick);
        ClientTickEvents.END_CLIENT_TICK.register(Recorder.instance()::endTick);
    }
}
