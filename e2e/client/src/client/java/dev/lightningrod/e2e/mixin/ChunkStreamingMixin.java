package dev.lightningrod.e2e.mixin;

import dev.lightningrod.e2e.Recorder;
import net.minecraft.client.network.ClientPlayNetworkHandler;
import net.minecraft.network.packet.s2c.play.ChunkDataS2CPacket;
import net.minecraft.network.packet.s2c.play.ChunkSentS2CPacket;
import net.minecraft.network.packet.s2c.play.GameJoinS2CPacket;
import net.minecraft.network.packet.s2c.play.GameStateChangeS2CPacket;
import net.minecraft.network.packet.s2c.play.StartChunkSendS2CPacket;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ClientPlayNetworkHandler.class)
abstract class ChunkStreamingMixin {
    @Inject(method = "onBlockBreakingProgress", at = @At("TAIL"))
    private void breaking(net.minecraft.network.packet.s2c.play.BlockBreakingProgressS2CPacket packet, CallbackInfo info) {
        Recorder.instance().blockBreaking(packet.getPos(), packet.getProgress());
    }

    @Inject(method = "onGameJoin", at = @At("TAIL"))
    private void gameJoin(GameJoinS2CPacket packet, CallbackInfo info) {
        Recorder.instance().gameJoin();
    }

    @Inject(method = "onGameStateChange", at = @At("TAIL"))
    private void gameStateChange(GameStateChangeS2CPacket packet, CallbackInfo info) {
        Recorder.instance().gameStateChange(((GameStateChangeReasonAccessor) (Object) packet.getReason()).lightningRod$id(), packet.getValue());
    }

    // NetworkThreadUtils schedules this handler onto the client thread. At HEAD that produces an
    // observation for the scheduling attempt and the actual handler invocation. TAIL observes only
    // successfully handled packets.
    @Inject(method = "onChunkData", at = @At("TAIL"))
    private void chunkData(ChunkDataS2CPacket packet, CallbackInfo info) {
        Recorder.instance().chunkData(
            packet.getChunkX(), packet.getChunkZ(),
            packet.getLightData().getInitedSky().cardinality(),
            packet.getLightData().getInitedBlock().cardinality(),
            packet.getLightData().getSkyNibbles().size(),
            packet.getLightData().getBlockNibbles().size()
        );
    }

    @Inject(method = "onStartChunkSend", at = @At("TAIL"))
    private void chunkBatchStart(StartChunkSendS2CPacket packet, CallbackInfo info) {
        Recorder.instance().chunkBatchStart();
    }

    @Inject(method = "onChunkSent", at = @At("TAIL"))
    private void chunkBatchFinished(ChunkSentS2CPacket packet, CallbackInfo info) {
        Recorder.instance().chunkBatchFinished(packet.batchSize());
    }
}
