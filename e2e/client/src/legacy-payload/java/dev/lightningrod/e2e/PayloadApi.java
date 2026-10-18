package dev.lightningrod.e2e;

import net.fabricmc.fabric.api.networking.v1.PayloadTypeRegistry;

final class PayloadApi {
    static void register() {
        PayloadTypeRegistry.playC2S().register(TestClient.Message.TYPE, TestClient.Message.CODEC);
        PayloadTypeRegistry.playS2C().register(TestClient.Message.TYPE, TestClient.Message.CODEC);
    }
}
