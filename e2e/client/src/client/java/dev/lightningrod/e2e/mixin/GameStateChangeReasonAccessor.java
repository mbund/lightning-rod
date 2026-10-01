package dev.lightningrod.e2e.mixin;

import net.minecraft.network.protocol.game.ClientboundGameEventPacket;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(ClientboundGameEventPacket.Type.class)
public interface GameStateChangeReasonAccessor {
    @Accessor("id")
    int lightningRod$id();
}
