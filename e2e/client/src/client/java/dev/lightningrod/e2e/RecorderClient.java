package dev.lightningrod.e2e;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientConfigurationConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.message.v1.ClientReceiveMessageEvents;
import net.minecraft.client.multiplayer.chat.ChatTrustLevel;
import net.minecraft.network.chat.ClickEvent;
import net.minecraft.network.chat.HoverEvent;

public final class RecorderClient implements ClientModInitializer {
    @Override public void onInitializeClient() {
        TestClient.register();
        Recorder.instance().configure();
        ClientReceiveMessageEvents.GAME.register((message, overlay) -> {
            Recorder recorder = Recorder.instance();
            recorder.chatReceived(message.getString());
            if (recorder.enabled && message.getStyle().getClickEvent() instanceof ClickEvent.RunCommand action) {
                String hover = message.getStyle().getHoverEvent() instanceof HoverEvent.ShowText tooltip ? tooltip.value().getString() : null;
                recorder.fixture.chatAction(message.getString(), action.command(), hover);
            }
        });
        // Player chat, with the trust the client shows it with, as ChatListener judges it.
        ClientReceiveMessageEvents.CHAT.register((message, signed, sender, type, received) -> {
            String trust = signed == null ? "NOT_SECURE" : ChatTrustLevel.evaluate(signed, message, received).name();
            Recorder.instance().playerChatReceived(message.getString(), trust);
        });
        ClientConfigurationConnectionEvents.START.register((handler, client) -> Recorder.instance().configurationStarted());
        ClientPlayConnectionEvents.JOIN.register((handler, sender, client) -> {
            Recorder recorder = Recorder.instance();
            recorder.playStarted();
            if (recorder.enabled) recorder.fixture.client.send("sync");
        });
        ClientPlayConnectionEvents.DISCONNECT.register((handler, client) -> Recorder.instance().disconnected());
        ClientTickEvents.END_CLIENT_TICK.register(client -> {
            Recorder.instance().advance(client);
            EntityTrace.instance().tick(client);
        });
        ClientLifecycleEvents.CLIENT_STOPPING.register(client -> Recorder.instance().write());
    }
}
