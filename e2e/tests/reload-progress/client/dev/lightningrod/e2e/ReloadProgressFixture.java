package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.ArrayDeque;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelPromise;
import net.minecraft.client.Minecraft;
import io.netty.util.ReferenceCountUtil;
import net.minecraft.network.protocol.configuration.ClientboundRegistryDataPacket;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class ReloadProgressFixture extends Fixture {
    private static final double FIRST_X = 5.5;
    private static final double FINAL_X = 8.5;
    private static final float FINAL_HEALTH = 7;
    private final AckGate gate = new AckGate();
    private int readyJoin;
    private boolean installed;
    private boolean configurationReloadRequested;
    private String progressed;
    private volatile long heldNs;

    ReloadProgressFixture(Recorder recorder) { super(recorder); }

    @Override boolean encrypted() { return true; }

    @Override void connected(Minecraft game) {
        if (!r.peer.equals("alice") || installed) return;
        var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        channel.pipeline().addBefore("encoder", "reload-ack-gate", gate);
        channel.pipeline().addAfter("decoder", "reload-configuration-gate", new ChannelInboundHandlerAdapter() {
            @Override public void handlerAdded(ChannelHandlerContext ctx) {
                gate.inputContext = ctx;
            }

            @Override public void channelRead(ChannelHandlerContext ctx, Object message) {
                if (message instanceof ClientboundRegistryDataPacket && gate.phase == AckGate.Phase.CONFIGURATION && !gate.holdingInput) {
                    gate.holdingInput = true;
                    heldNs = System.nanoTime();
                    r.marker("alice-configuration-held");
                }
                if (!gate.holdingInput) {
                    ctx.fireChannelRead(message);
                    return;
                }
                if (gate.input.size() == 256) {
                    ReferenceCountUtil.release(message);
                    client.fail("configuration_input_queue_overflow");
                    ctx.close();
                    return;
                }
                gate.input.add(message);
            }
        });
        installed = true;
    }

    @Override void reconfigurationEncoded() {
        if (!r.peer.equals("alice") || gate.phase != AckGate.Phase.ACKNOWLEDGMENT) return;
        heldNs = System.nanoTime();
        gate.holding = true;
    }

    @Override void poll(Minecraft game) {
        if (r.peer.equals("bob") && !configurationReloadRequested && Files.exists(r.artifacts.resolve("alice-configuration-held"))) {
            configurationReloadRequested = true;
            client.send("reload_configuring");
        }
        if (heldNs == 0) return;
        if (Files.exists(r.artifacts.resolve(gate.phase == AckGate.Phase.ACKNOWLEDGMENT ? "resume-alice-ack" : "resume-alice-configuration"))) {
            heldNs = 0;
            gate.context.executor().execute(gate::release);
        } else if (System.nanoTime() - heldNs > 30_000_000_000L) {
            client.fail("reload_waited_for_configuration_acknowledgment");
        }
    }

    @Override void message(String text) {
        if (text.equals("ack_progressed") || text.equals("configuration_progressed")) progressed = text;
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0 || GuiApi.screen(game) != null) return;
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.send("ready");
        }
        if (r.joins < 2) return;
        if (r.peer.equals("bob")) {
            if (progressed == null) return;
            boolean complete = progressed.equals("configuration_progressed");
            var alice = game.level.players().stream().filter(player -> player.getName().getString().equals("alice")).findFirst();
            if (alice.isEmpty() || !close(alice.get().getX(), complete ? FINAL_X : FIRST_X, 0.05)) return;
            r.marker(complete ? "resume-alice-configuration" : "resume-alice-ack");
            progressed = null;
            if (complete) client.pass("simulation_progressed_and_replicated_configuring_player");
        } else if (close(game.player.getHealth(), FINAL_HEALTH, 0.01) && close(game.player.getX(), FINAL_X, 0.05)) {
            client.pass("configuration_resynchronized_current_player_state");
        }
    }

    private static final class AckGate extends ChannelOutboundHandlerAdapter {
        private enum Phase { ACKNOWLEDGMENT, CONFIGURATION, COMPLETE }
        private volatile Phase phase = Phase.ACKNOWLEDGMENT;
        private record Write(ByteBuf bytes, ChannelPromise promise) {}
        private final ArrayDeque<Write> pending = new ArrayDeque<>();
        private final ArrayDeque<Object> input = new ArrayDeque<>();
        private ChannelHandlerContext context;
        private ChannelHandlerContext inputContext;
        private int retained;
        private boolean holding;
        private boolean holdingInput;

        @Override public void handlerAdded(ChannelHandlerContext ctx) {
            context = ctx;
            ctx.channel().closeFuture().addListener(future -> {
                while (!input.isEmpty()) ReferenceCountUtil.release(input.remove());
                while (!pending.isEmpty()) {
                    Write write = pending.remove();
                    write.bytes.release();
                    write.promise.tryFailure(new IllegalStateException("closed while holding configuration acknowledgment"));
                }
            });
        }

        @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
            if (!holding || !(message instanceof ByteBuf bytes)) {
                ctx.write(message, promise);
                return;
            }
            retained += bytes.readableBytes();
            if (retained > 1024 * 1024) {
                bytes.release();
                promise.setFailure(new IllegalStateException("configuration acknowledgment queue overflow"));
                ctx.close();
                return;
            }
            pending.add(new Write(bytes, promise));
        }

        private void release() {
            holding = false;
            holdingInput = false;
            phase = phase == Phase.ACKNOWLEDGMENT ? Phase.CONFIGURATION : Phase.COMPLETE;
            while (!pending.isEmpty()) {
                Write write = pending.remove();
                context.write(write.bytes, write.promise);
            }
            retained = 0;
            context.flush();
            while (!input.isEmpty()) inputContext.fireChannelRead(input.remove());
            inputContext.fireChannelReadComplete();
        }
    }
}
