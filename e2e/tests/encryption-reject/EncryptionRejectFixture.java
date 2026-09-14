package dev.lightningrod.e2e;

import net.minecraft.client.MinecraftClient;

final class EncryptionRejectFixture extends Fixture {
    EncryptionRejectFixture(Recorder r) { super(r); }

    @Override void disconnected(MinecraftClient client, String title) {
        if (r.playTick < 0) r.pass(client, "encryption_rejected_before_play");
        else super.disconnected(client, title);
    }

    @Override void tick(MinecraftClient client, int loaded, int missing) {
        r.fail(client, "invalid_encryption_accepted");
    }
}
