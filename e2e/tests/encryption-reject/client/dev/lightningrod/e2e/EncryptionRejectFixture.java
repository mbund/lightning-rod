package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.network.FriendlyByteBuf;
import io.netty.buffer.ByteBuf;

final class EncryptionRejectFixture extends Fixture {
    private volatile boolean encryptionAnswered;
    EncryptionRejectFixture(Recorder r) { super(r); }

    @Override void encryptionResponseEncoded(ByteBuf encoded) {
        var packet = new FriendlyByteBuf(encoded.duplicate());
        packet.readVarInt();
        int secretLength = packet.readVarInt();
        packet.skipBytes(secretLength);
        int tokenLength = packet.readVarInt();
        if (tokenLength != secretLength || tokenLength == 0 || packet.readableBytes() != tokenLength)
            throw new IllegalStateException("Unexpected encryption response layout");
        packet.setZero(packet.readerIndex(), tokenLength);
        encryptionAnswered = true;
    }

    @Override void disconnected(Minecraft game, String title) {
        if (encryptionAnswered && r.playTick < 0 && r.joins == 0)
            client.pass("encryption_rejected_before_play");
        else super.disconnected(game, title);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        client.fail("invalid_encryption_accepted");
    }
}
