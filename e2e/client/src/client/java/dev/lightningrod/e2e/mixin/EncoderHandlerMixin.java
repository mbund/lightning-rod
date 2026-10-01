package dev.lightningrod.e2e.mixin;
import dev.lightningrod.e2e.Recorder;
import io.netty.buffer.ByteBuf; import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.PacketEncoder;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ServerboundChunkBatchReceivedPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerLoadedPacket;
import org.spongepowered.asm.mixin.Mixin; import org.spongepowered.asm.mixin.injection.At; import org.spongepowered.asm.mixin.injection.Inject; import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(PacketEncoder.class) abstract class EncoderHandlerMixin {
 @Inject(method="encode", at=@At("RETURN")) private void capture(ChannelHandlerContext c, Packet<?> p, ByteBuf b, CallbackInfo i) {
  if (p instanceof ServerboundChunkBatchReceivedPacket packet) Recorder.instance().chunkBatchAcknowledged(packet.desiredChunksPerTick());
  if (p instanceof ServerboundPlayerLoadedPacket) Recorder.instance().playerLoadedSent();
  if (p instanceof net.minecraft.network.protocol.game.ServerboundConfigurationAcknowledgedPacket) Recorder.instance().reconfigurationEncoded();
 }
}
