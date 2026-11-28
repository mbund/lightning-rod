package dev.lightningrod.e2e.mixin;

import dev.lightningrod.e2e.EntitySounds;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.protocol.game.ClientboundSoundEntityPacket;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/// Notes each sound the server sent following an entity, before the client tries to play it.
@Mixin(ClientPacketListener.class)
abstract class EntitySoundMixin {
    @Inject(method = "handleSoundEntityEvent", at = @At("HEAD"))
    private void note(ClientboundSoundEntityPacket packet, CallbackInfo info) {
        EntitySounds.heard(String.valueOf(packet.getSound().value()), packet.getId());
    }
}
