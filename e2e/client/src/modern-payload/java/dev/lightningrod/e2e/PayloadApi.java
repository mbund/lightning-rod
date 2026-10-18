package dev.lightningrod.e2e;

import net.fabricmc.fabric.api.networking.v1.PayloadTypeRegistry;

final class PayloadApi {
    static void register() {
        PayloadTypeRegistry.serverboundPlay().register(TestClient.Message.TYPE, TestClient.Message.CODEC);
        PayloadTypeRegistry.clientboundPlay().register(TestClient.Message.TYPE, TestClient.Message.CODEC);
    }
}
