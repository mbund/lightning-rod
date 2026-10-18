package dev.lightningrod.e2e;

import java.nio.file.Path;
import java.util.ArrayDeque;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;

final class ReloadFragment extends ChannelOutboundHandlerAdapter {
    private record Write(ByteBuf bytes, ChannelPromise promise) {}
    private final ArrayDeque<Write> pending = new ArrayDeque<>();
    private final Path artifacts;
    private final String peer;
    private Write acknowledgement;
    volatile int generation;
    volatile int released;
    private ChannelHandlerContext context;
    private int retained;
    boolean capture;
    private boolean holding;

    ReloadFragment(Path artifacts, String peer) {
        this.artifacts = artifacts;
        this.peer = peer;
    }

    @Override public void handlerAdded(ChannelHandlerContext ctx) {
        context = ctx;
        ctx.channel().closeFuture().addListener(future -> {
            if (acknowledgement != null) {
                pending.add(acknowledgement);
                acknowledgement = null;
            }
            while (!pending.isEmpty()) {
                Write write = pending.remove();
                write.bytes.release();
                write.promise.tryFailure(new IllegalStateException("closed during fragmented reload"));
            }
        });
    }

    @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
        if (!(message instanceof ByteBuf bytes)) {
            ctx.write(message, promise);
            return;
        }
        if (capture) {
            capture = false;
            acknowledgement = new Write(bytes, promise);
        } else if (acknowledgement != null) {
            // One encrypted write: complete acknowledgement followed by an incomplete frame.
            ByteBuf prefix = ctx.alloc().buffer(acknowledgement.bytes.readableBytes() + 1);
            prefix.writeBytes(acknowledgement.bytes);
            prefix.writeByte(bytes.readByte());
            acknowledgement.bytes.release();
            ctx.writeAndFlush(prefix, acknowledgement.promise);
            acknowledgement = null;
            holding = true;
            pending.add(new Write(bytes, promise));
            retained = bytes.readableBytes();
            generation++;
            Artifacts.publish(artifacts.resolve(peer + ".reload-fragment-" + generation), "ciphertext prefix sent\n");
        } else if (holding) {
            retained += bytes.readableBytes();
            if (retained > 1024 * 1024) {
                bytes.release();
                promise.setFailure(new IllegalStateException("reload fragment queue overflow"));
                ctx.close();
                return;
            }
            pending.add(new Write(bytes, promise));
        } else ctx.write(bytes, promise);
    }

    void resumed() {
        if (!holding) return;
        holding = false;
        while (!pending.isEmpty()) {
            Write write = pending.remove();
            context.write(write.bytes, write.promise);
        }
        retained = 0;
        released++;
        context.flush();
    }
}
