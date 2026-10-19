package dev.lightningrod.e2e;

import java.nio.channels.ClosedChannelException;
import java.nio.file.Files;
import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelDuplexHandler;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelPromise;
import io.netty.util.ReferenceCountUtil;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class ReloadWorldFixture extends Fixture {
    private static final int RENDER_DISTANCE = 32;
    private static final int EXPECTED_CHUNKS = (2 * RENDER_DISTANCE + 1) * (2 * RENDER_DISTANCE + 1);
    private static final int MINIMUM_PROGRESS_TICKS = 10;
    private static final double BOB_INITIAL_X = 8.5;
    private static final double BOB_RESUMED_X = 12.5;
    private static final float BOB_RESUMED_HEALTH = 14;
    private static final long ONE_WAY_LATENCY_MS = 500;
    private boolean installed;
    private int readyJoin;
    private boolean progressed;
    private boolean observedSlowPlayer;
    private volatile long acknowledgmentNs;
    private long rejoinedNs;
    private Long reloadMs;

    ReloadWorldFixture(Recorder recorder) { super(recorder); }
    @Override int renderDistance() { return RENDER_DISTANCE; }
    @Override boolean encrypted() { return true; }

    @Override void connected(Minecraft game) {
        if (!r.peer.equals("bob") || installed) return;
        var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        channel.pipeline().addFirst("e2e-latency", new Latency());
        installed = true;
        client.event("network_latency", "one_way_ms", ONE_WAY_LATENCY_MS);
    }

    @Override void reconfigurationEncoded() {
        if (r.peer.equals("bob")) acknowledgmentNs = System.nanoTime();
    }

    @Override void message(String text) {
        if (text.equals("simulation_progressed")) {
            progressed = true;
            if (r.peer.equals("alice")) r.marker("resume-bob-configuration");
        } else if (text.startsWith("verified ")) {
            String[] fields = text.split(" ");
            if (fields.length != 3 || Long.parseLong(fields[2]) < MINIMUM_PROGRESS_TICKS) throw new IllegalArgumentException("invalid reload verification");
            reloadMs = Long.parseLong(fields[1]);
            client.event("reload_verified", "reload_ms", reloadMs, "slow_configuration_ticks", Long.parseLong(fields[2]));
        } else throw new IllegalArgumentException("unexpected reload message: " + text);
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0 || GuiApi.screen(game) != null) return;
        if (reloadMs != null && readyJoin == 2) {
            if (r.peer.equals("alice") && !observedSlowPlayer) return;
            if (!client.screenshot("reloaded_world").done()) return;
            client.mark(r.peer + ".verified");
            for (String peer : r.expectedPeers) if (!client.marked(peer + ".verified")) return;
            client.pass("reload_world_players_and_latency_verified");
            return;
        }
        boolean resumed = r.joins == 2;
        if (r.joins > 2) { client.fail("unexpected_additional_reload"); return; }
        if (resumed && r.peer.equals("bob") && rejoinedNs == 0) {
            rejoinedNs = System.nanoTime();
            if (acknowledgmentNs == 0 || rejoinedNs - acknowledgmentNs < 2 * ONE_WAY_LATENCY_MS * 1_000_000L) {
                client.fail("slow_client_latency_was_not_applied");
                return;
            }
        }
        if (game.level.players().size() != 2) return;
        var bob = game.level.players().stream().filter(player -> player.getName().getString().equals("bob")).findFirst();
        if (bob.isEmpty() || !close(bob.get().getX(), resumed ? BOB_RESUMED_X : BOB_INITIAL_X, 0.05)) return;
        if (r.peer.equals("alice") && progressed) observedSlowPlayer = true;
        if (loaded < EXPECTED_CHUNKS || missing != 0) return;
        if (!game.level.getBlockState(new BlockPos(3, 65, 3)).is(Blocks.GOLD_BLOCK)
                || !game.level.getBlockState(new BlockPos(4, 65, 3)).is(Blocks.DIAMOND_BLOCK)) {
            client.fail("world_edits_missing");
            return;
        }
        if (resumed && r.peer.equals("bob") && !close(game.player.getHealth(), BOB_RESUMED_HEALTH, 0.01)) return;
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.event("terrain_complete", "join", readyJoin, "loaded", loaded, "missing", missing);
            client.send("terrain_ready");
        }
    }

    private final class Latency extends ChannelDuplexHandler {
        private static final long MAXIMUM_BYTES = 32L * 1024 * 1024;
        private record Pending(Object message, ChannelPromise promise, int bytes) {}
        private final ArrayDeque<Pending> pending = new ArrayDeque<>();
        private long retained;
        private ChannelHandlerContext context;
        private boolean closed;
        private boolean releasedConfiguration;

        @Override public void handlerAdded(ChannelHandlerContext ctx) { context = ctx; }
        @Override public void channelRead(ChannelHandlerContext ctx, Object message) { enqueue(message, null); }
        @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) { enqueue(message, promise); }
        @Override public void channelReadComplete(ChannelHandlerContext ctx) {
            ctx.executor().schedule(() -> { if (!closed) ctx.fireChannelReadComplete(); }, ONE_WAY_LATENCY_MS, TimeUnit.MILLISECONDS);
        }

        private void enqueue(Object message, ChannelPromise promise) {
            if (closed) {
                ReferenceCountUtil.release(message);
                if (promise != null) promise.tryFailure(new ClosedChannelException());
                return;
            }
            int bytes = message instanceof ByteBuf buffer ? buffer.readableBytes() : 0;
            retained += bytes;
            pending.addLast(new Pending(message, promise, bytes));
            if (retained > MAXIMUM_BYTES) {
                context.fireExceptionCaught(new IllegalStateException("latency queue overflow"));
                context.close();
                return;
            }
            context.executor().schedule(this::deliver, ONE_WAY_LATENCY_MS, TimeUnit.MILLISECONDS);
        }

        private void deliver() {
            if (closed) return;
            // Bob cannot receive the release signal over his paused socket.
            if (acknowledgmentNs != 0 && !releasedConfiguration) {
                if (!Files.exists(r.artifacts.resolve("resume-bob-configuration"))) {
                    context.executor().schedule(this::deliver, 10, TimeUnit.MILLISECONDS);
                    return;
                }
                releasedConfiguration = true;
            }
            Pending next = pending.removeFirst();
            retained -= next.bytes;
            if (next.promise == null) context.fireChannelRead(next.message);
            else context.writeAndFlush(next.message, next.promise);
        }

        @Override public void channelInactive(ChannelHandlerContext ctx) {
            closed = true;
            while (!pending.isEmpty()) {
                Pending next = pending.removeFirst();
                ReferenceCountUtil.release(next.message);
                if (next.promise != null) next.promise.tryFailure(new ClosedChannelException());
            }
            retained = 0;
            ctx.fireChannelInactive();
        }
    }
}
