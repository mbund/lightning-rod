package dev.mbund.lightningrod.conformance.mixin;
import dev.mbund.lightningrod.conformance.Recorder;
import io.netty.buffer.ByteBuf; import io.netty.buffer.ByteBufUtil; import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.handler.DecoderHandler;
import org.spongepowered.asm.mixin.Mixin; import org.spongepowered.asm.mixin.injection.At; import org.spongepowered.asm.mixin.injection.Inject; import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import java.util.List;
@Mixin(DecoderHandler.class) abstract class DecoderHandlerMixin {
 @Inject(method="decode", at=@At("HEAD")) private void capture(ChannelHandlerContext c, ByteBuf b, List<Object> o, CallbackInfo i) { Recorder.instance().inboundRaw(ByteBufUtil.getBytes(b, b.readerIndex(), b.readableBytes(), false)); }
}
