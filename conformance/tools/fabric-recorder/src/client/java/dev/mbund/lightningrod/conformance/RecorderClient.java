package dev.mbund.lightningrod.conformance;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientConfigurationConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.message.v1.ClientReceiveMessageEvents;

public final class RecorderClient implements ClientModInitializer {
    @Override public void onInitializeClient() {
        Recorder.instance().configure();
        ClientReceiveMessageEvents.GAME.register((message, overlay) -> Recorder.instance().chatReceived(message.getString()));
        ClientConfigurationConnectionEvents.START.register((handler, client) -> Recorder.instance().configurationStarted());
        ClientPlayConnectionEvents.JOIN.register((handler, sender, client) -> Recorder.instance().playStarted());
        ClientPlayConnectionEvents.DISCONNECT.register((handler, client) -> Recorder.instance().disconnected());
        ClientTickEvents.END_CLIENT_TICK.register(client -> Recorder.instance().advance(client));
        ClientLifecycleEvents.CLIENT_STOPPING.register(client -> Recorder.instance().write(client));
    }
}
