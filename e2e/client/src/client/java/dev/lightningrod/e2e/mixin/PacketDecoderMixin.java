package dev.lightningrod.e2e.mixin;

import java.util.List;
import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.lightningrod.e2e.EntityTrace;
import dev.lightningrod.e2e.Recorder;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.PacketDecoder;
import org.spongepowered.asm.mixin.Mixin;

@Mixin(PacketDecoder.class)
abstract class PacketDecoderMixin {
    @WrapMethod(method = "decode")
    private void captureFailure(ChannelHandlerContext context, ByteBuf bytes, List<Object> output, Operation<Void> original) throws Exception {
        int start = bytes.readerIndex();
        try {
            int before = output.size();
            original.call(context, bytes, output);
            if (output.size() > before) EntityTrace.instance().decoded(output.get(output.size() - 1), bytes.readerIndex() - start);
        } catch (Exception error) {
            Recorder.instance().packetFailed(ByteBufUtil.getBytes(bytes, start, bytes.writerIndex() - start), error);
            throw error;
        }
    }
}
