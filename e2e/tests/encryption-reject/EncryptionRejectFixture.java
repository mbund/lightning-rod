package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class EncryptionRejectFixture extends Fixture {
    EncryptionRejectFixture(Recorder r) { super(r); }

    @Override void disconnected(Minecraft client, String title) {
        if (r.playTick < 0) r.pass(client, "encryption_rejected_before_play");
        else super.disconnected(client, title);
    }

    @Override void tick(Minecraft client, int loaded, int missing) {
        r.fail(client, "invalid_encryption_accepted");
    }
}
