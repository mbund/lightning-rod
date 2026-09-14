package dev.lightningrod.e2e.mixin;
import dev.lightningrod.e2e.Recorder;
import io.netty.buffer.ByteBuf; import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.handler.EncoderHandler; import net.minecraft.network.packet.Packet;
import net.minecraft.network.packet.c2s.play.AcknowledgeChunksC2SPacket;
import net.minecraft.network.packet.c2s.play.PlayerLoadedC2SPacket;
import org.spongepowered.asm.mixin.Mixin; import org.spongepowered.asm.mixin.injection.At; import org.spongepowered.asm.mixin.injection.Inject; import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(EncoderHandler.class) abstract class EncoderHandlerMixin {
 @Inject(method="encode", at=@At("RETURN")) private void capture(ChannelHandlerContext c, Packet<?> p, ByteBuf b, CallbackInfo i) {
  if (p instanceof AcknowledgeChunksC2SPacket packet) Recorder.instance().chunkBatchAcknowledged(packet.desiredChunksPerTick());
  if (p instanceof PlayerLoadedC2SPacket) Recorder.instance().playerLoadedSent();
  if (p instanceof net.minecraft.network.packet.c2s.play.AcknowledgeReconfigurationC2SPacket) Recorder.instance().reconfigurationEncoded();
 }
}
