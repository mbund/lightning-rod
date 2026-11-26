package dev.lightningrod.e2e.mixin;

import dev.lightningrod.e2e.EntityTrace;
import dev.lightningrod.e2e.EntityApi;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.protocol.game.ClientboundAddEntityPacket;
import net.minecraft.network.protocol.game.ClientboundEntityPositionSyncPacket;
import net.minecraft.network.protocol.game.ClientboundMoveEntityPacket;
import net.minecraft.network.protocol.game.ClientboundRemoveEntitiesPacket;
import net.minecraft.network.protocol.game.ClientboundSetEntityMotionPacket;
import net.minecraft.network.protocol.game.ClientboundTeleportEntityPacket;
import net.minecraft.world.entity.Entity;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/// Each entity packet as the client handled it, on the game thread: a handler called on the
/// network thread hands itself over before it reaches its end.
@Mixin(ClientPacketListener.class)
abstract class EntityTraceMixin {
    @Inject(method = "handleAddEntity", at = @At("TAIL"))
    private void traceSpawn(ClientboundAddEntityPacket packet, CallbackInfo info) {
        EntityTrace.instance().packet("spawn", packet.getId());
    }

    @Inject(method = "handleTeleportEntity", at = @At("TAIL"))
    private void traceTeleport(ClientboundTeleportEntityPacket packet, CallbackInfo info) {
        EntityTrace.instance().packet("teleport", packet.id());
    }

    @Inject(method = "handleEntityPositionSync", at = @At("TAIL"))
    private void traceSync(ClientboundEntityPositionSyncPacket packet, CallbackInfo info) {
        EntityTrace.instance().packet("sync", packet.id());
    }

    @Inject(method = "handleMoveEntity", at = @At("TAIL"))
    private void traceMove(ClientboundMoveEntityPacket packet, CallbackInfo info) {
        Minecraft client = Minecraft.getInstance();
        if (client.level == null) return;
        Entity entity = packet.getEntity(client.level);
        if (entity != null) EntityTrace.instance().packet("move", entity.getId());
    }

    @Inject(method = "handleSetEntityMotion", at = @At("TAIL"))
    private void traceMotion(ClientboundSetEntityMotionPacket packet, CallbackInfo info) {
        EntityTrace.instance().packet("motion", EntityApi.motionId(packet));
    }

    @Inject(method = "handleRemoveEntities", at = @At("TAIL"))
    private void traceRemoval(ClientboundRemoveEntitiesPacket packet, CallbackInfo info) {
        packet.getEntityIds().forEach(id -> EntityTrace.instance().removed(id));
    }
}
