package dev.mbund.lightningrod.conformance.mixin;

import dev.mbund.lightningrod.conformance.Recorder;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.handler.DecoderHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.List;

/** Captures packet-id plus body after splitting/decompression and before decode. */
@Mixin(DecoderHandler.class)
abstract class DecoderHandlerMixin {
    @Inject(method = "decode", at = @At("HEAD"))
    private void conformance$inbound(ChannelHandlerContext context, ByteBuf input, List<Object> output, CallbackInfo ci) {
        Recorder.instance().inboundRaw(ByteBufUtil.getBytes(input, input.readerIndex(), input.readableBytes(), false));
    }
}
