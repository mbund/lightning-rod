package dev.mbund.lightningrod.conformance.mixin;

import net.minecraft.network.packet.s2c.play.GameStateChangeS2CPacket;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(GameStateChangeS2CPacket.Reason.class)
public interface GameStateChangeReasonAccessor {
    @Accessor("id")
    int lightningRod$id();
}
