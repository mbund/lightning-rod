package dev.mbund.lightningrod.conformance.mixin;

import dev.mbund.lightningrod.conformance.Recorder;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.handler.EncoderHandler;
import net.minecraft.network.packet.Packet;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Captures packet-id plus body after encode and before framing/compression. */
@Mixin(EncoderHandler.class)
abstract class EncoderHandlerMixin {
    @Inject(method = "encode", at = @At("RETURN"))
    private void conformance$outbound(ChannelHandlerContext context, Packet<?> packet, ByteBuf output, CallbackInfo ci) {
        Recorder.instance().outboundRaw(ByteBufUtil.getBytes(output, output.readerIndex(), output.readableBytes(), false));
    }
}
