package dev.lightningrod.e2e;

import net.minecraft.network.protocol.game.ClientboundSetEntityMotionPacket;

/// What changed between releases in the entity packets the traces read: before 26.1.
public final class EntityApi {
    private EntityApi() {}

    public static int motionId(ClientboundSetEntityMotionPacket packet) { return packet.getId(); }
}
