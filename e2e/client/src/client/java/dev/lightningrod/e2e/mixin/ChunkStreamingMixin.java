package dev.lightningrod.e2e.mixin;

import dev.lightningrod.e2e.Recorder;
import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.protocol.game.ClientboundChunkBatchFinishedPacket;
import net.minecraft.network.protocol.game.ClientboundChunkBatchStartPacket;
import net.minecraft.network.protocol.game.ClientboundGameEventPacket;
import net.minecraft.network.protocol.game.ClientboundLevelChunkWithLightPacket;
import net.minecraft.network.protocol.game.ClientboundLoginPacket;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ClientPacketListener.class)
abstract class ChunkStreamingMixin {
    @Inject(method = "handleBlockDestruction", at = @At("TAIL"))
    private void breaking(net.minecraft.network.protocol.game.ClientboundBlockDestructionPacket packet, CallbackInfo info) {
        Recorder.instance().blockBreaking(packet.getPos(), packet.getProgress());
    }

    @Inject(method = "handleLogin", at = @At("TAIL"))
    private void gameJoin(ClientboundLoginPacket packet, CallbackInfo info) {
        Recorder.instance().gameJoin();
    }

    @Inject(method = "handleGameEvent", at = @At("TAIL"))
    private void gameStateChange(ClientboundGameEventPacket packet, CallbackInfo info) {
        Recorder.instance().gameStateChange(((GameStateChangeReasonAccessor) (Object) packet.getEvent()).lightningRod$id(), packet.getParam());
    }

    // NetworkThreadUtils schedules this handler onto the client thread. At HEAD that produces an
    // observation for the scheduling attempt and the actual handler invocation. TAIL observes only
    // successfully handled packets.
    @Inject(method = "handleLevelChunkWithLight", at = @At("TAIL"))
    private void chunkData(ClientboundLevelChunkWithLightPacket packet, CallbackInfo info) {
        Recorder.instance().chunkData(
            packet.getX(), packet.getZ(),
            packet.getLightData().getSkyYMask().cardinality(),
            packet.getLightData().getBlockYMask().cardinality(),
            packet.getLightData().getSkyUpdates().size(),
            packet.getLightData().getBlockUpdates().size()
        );
    }

    @Inject(method = "handleChunkBatchStart", at = @At("TAIL"))
    private void chunkBatchStart(ClientboundChunkBatchStartPacket packet, CallbackInfo info) {
        Recorder.instance().chunkBatchStart();
    }

    @Inject(method = "handleChunkBatchFinished", at = @At("TAIL"))
    private void chunkBatchFinished(ClientboundChunkBatchFinishedPacket packet, CallbackInfo info) {
        Recorder.instance().chunkBatchFinished(packet.batchSize());
    }
}
