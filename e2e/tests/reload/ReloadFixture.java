package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import net.minecraft.util.Mth;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;

final class ReloadFixture extends Fixture {
    private ReloadFragment reloadFragment;
    private net.minecraft.network.Connection reloadConnection;
    private volatile boolean reloadOptions;
    private int reloadStage;
    private int reloadRequests;
    private long reloadMovedTick = -1;
    private int reloadVerified = -1;
    private int reloadBarRequested = -1;
    private double reloadX;
    private double reloadZ;
    private volatile int requestedMessages;
    private volatile int successfulMessages;
    private volatile int rollbackMessages;
    private volatile int rejectedMessages;
    private volatile boolean invalidFeedback;
    private int cursorStage = -1;
    private long cursorReady;
    private long inventoryMismatchTick = -1;

    ReloadFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    @Override void chat(String text) {
        super.chat(text);
        if (text.equals("Reload requested.")) requestedMessages++;
        else if (text.matches("Reload successful \\(\\d+ ms\\)\\.")) successfulMessages++;
        else if (text.matches("Reload failed; rolled back successfully \\(\\d+ ms\\)\\.")) rollbackMessages++;
        else if (text.matches("Reload rejected; server unchanged \\(\\d+ ms\\)\\.")) rejectedMessages++;
        else if (text.startsWith("Reload ")) invalidFeedback = true;
        if (r.peer.equals("alice") && successfulMessages + rollbackMessages + rejectedMessages > requestedMessages) invalidFeedback = true;
        if (!r.peer.equals("alice") && requestedMessages != 0) invalidFeedback = true;
    }

    public void tick(Minecraft client, int loaded, int missing) {
        if (invalidFeedback) { r.fail(client, "invalid_reload_feedback_or_order"); return; }
        if (loaded < 9 || client.player == null) return;
        if (r.peer.equals("alice") && Files.exists(r.artifacts.resolve("reload-request-" + reloadRequests))) {
            client.getConnection().sendCommand(reloadRequests == 4 ? "reload_opaque" : reloadRequests == 5 ? "reload_signal" : "reload");
            r.marker("reload-requested-" + reloadRequests);
            reloadRequests++;
        }
        if (r.joins == reloadStage + 2 && GuiApi.screen(client) != null) return;
        var stack = client.player.getInventory().getItem(0);
        var cursor = client.player.containerMenu.getCarried();
        int bread = (stack.is(net.minecraft.world.item.Items.BREAD) ? stack.getCount() : 0)
            + (cursor.is(net.minecraft.world.item.Items.BREAD) ? cursor.getCount() : 0);
        boolean deletedCursor = client.player.hasInfiniteMaterials() && reloadStage == 3
            && cursorStage == reloadStage && r.joins == reloadStage + 1;
        if (bread != (deletedCursor ? 0 : 17)) {
            if (inventoryMismatchTick < 0) inventoryMismatchTick = r.tick;
            if (cursorStage >= 0 && r.tick - inventoryMismatchTick >= 40) {
                r.event("reload_inventory_mismatch", "joins", r.joins, "stage", reloadStage,
                    "slot", stack.toString(), "cursor", cursor.toString());
                r.fail(client, "reload_inventory_lost_or_duplicated");
            }
            return;
        }
        inventoryMismatchTick = -1;
        if (r.joins == reloadStage + 2) {
            if (stack.getCount() != 17 || !cursor.isEmpty()) {
                r.fail(client, "reload_cursor_not_returned_to_inventory");
                return;
            }
            for (int slot = 1; slot < client.player.getInventory().getContainerSize(); slot++) {
                if (!client.player.getInventory().getItem(slot).isEmpty()) {
                    r.fail(client, "reload_created_extra_inventory_stack_" + slot);
                    return;
                }
            }
            if (!r.close(client.player.getX(), reloadX, 0.01) || !r.close(client.player.getZ(), reloadZ, 0.01)) {
                r.fail(client, "reload_position_not_restored");
                return;
            }
            if (!((BossBarHudAccessor) GuiApi.bossBars(client)).lightningRod$bossBars().isEmpty()) {
                r.fail(client, "reload_bossbars_not_cleared");
                return;
            }
            reloadStage++;
            reloadMovedTick = -1;
            r.screenshot(client, "reload_return_" + reloadStage);
            r.event("reload_return", "generation", reloadStage, "joins", r.joins);
        }
        if (r.joins != reloadStage + 1) { r.fail(client, "unexpected_reload_join_count"); return; }
        if (reloadMovedTick < 0 && GuiApi.screen(client) == null) {
            if (client.level.players().size() != 2) return;
            reloadX = (r.peer.equals("alice") ? -3.5 : 3.5) + reloadStage;
            reloadZ = 3.5 + reloadStage;
            client.player.setPos(reloadX, 65, reloadZ);
            client.player.setYRot(r.peer.equals("alice") ? -90 : 90);
            client.getConnection().send(new ServerboundMovePlayerPacket.PosRot(reloadX, 65, reloadZ, client.player.getYRot(), 0, true, false));
            client.getConnection().sendChat(r.peer + " reload " + reloadStage);
            reloadMovedTick = r.tick;
        }
        if (reloadMovedTick < 0 || r.tick - reloadMovedTick < 20 || reloadVerified == reloadStage) return;
        String otherName = r.peer.equals("alice") ? "bob" : "alice";
        var other = client.level.players().stream().filter(p -> p.getName().getString().equals(otherName)).findFirst().orElse(null);
        if (other == null || client.level.players().size() != 2 || client.getConnection().getOnlinePlayers().size() != 2) return;
        double expectedX = (otherName.equals("alice") ? -3.5 : 3.5) + reloadStage;
        if (!r.close(other.getX(), expectedX, 0.1) || !r.close(other.getZ(), 3.5 + reloadStage, 0.1)
            || !r.close(Mth.wrapDegrees(other.getYHeadRot() - (otherName.equals("alice") ? -90 : 90)), 0, 2)) return;
        if (!r.receivedChat.contains("<" + otherName + "> " + otherName + " reload " + reloadStage)) return;
        if (reloadStage == 5) {
            if (r.peer.equals("alice") && (requestedMessages != 4 || successfulMessages != 2 || rollbackMessages != 1 || rejectedMessages != 1)) return;
            if (r.peer.equals("bob") && (requestedMessages != 0 || successfulMessages != 1 || rollbackMessages != 0 || rejectedMessages != 0)) return;
            if (r.missingChunks(client, 32) != 0 || !client.player.onGround() || !r.close(client.player.getY(), 65, 0.01)) return;
            r.screenshot(client, "reload_feedback");
            r.pass(client, "reload_player_signal_and_unknown_metadata_verified");
            return;
        }
        if (cursorStage != reloadStage) {
            r.screenshot(client, "reload_visible_peers_" + reloadStage);
            if (client.player.hasInfiniteMaterials()) {
                var screen = new InventoryFixture.CreativeScreen(client);
                GuiApi.screen(client, screen);
                screen.inventoryTab();
                if (reloadStage == 1 || reloadStage == 4) {
                    screen.pickSlot(36);
                    screen.pickSlot(37);
                    screen.pickSlot(37);
                    screen.pickSlot(36);
                }
                if (reloadStage != 4) screen.pickSlot(36);
                if (reloadStage == 3) screen.pickSlot(46);
                if (reloadStage == 4) {
                    screen.catalogTab();
                    screen.pickSlot(0);
                }
            } else {
                GuiApi.screen(client, new InventoryScreen(client.player));
                GameApi.inventoryClick(client, 36, 0, ClickType.PICKUP);
            }
            cursorStage = reloadStage;
            cursorReady = System.nanoTime() + 500_000_000L;
            return;
        }
        if (System.nanoTime() < cursorReady) return;
        boolean returnedCursor = client.player.hasInfiniteMaterials() && reloadStage == 4;
        int expectedSlot = returnedCursor ? 17 : 0;
        int expectedCursor = deletedCursor ? 0 : 17;
        if (returnedCursor) {
            if (cursor.isEmpty() || cursor.is(net.minecraft.world.item.Items.BREAD)) {
                r.fail(client, "reload_catalog_cursor_setup_failed");
                return;
            }
            expectedCursor = cursor.getCount();
        }
        if (client.player.getInventory().getItem(0).getCount() != expectedSlot || cursor.getCount() != expectedCursor) {
            r.fail(client, "reload_cursor_setup_failed");
            return;
        }
        if (reloadStage == 0) {
            r.marker(r.peer + ".reload-ready");
            if (!Files.exists(r.artifacts.resolve("reload-rejected"))) return;
        }
        if (reloadBarRequested != reloadStage) {
            client.getConnection().sendCommand("reload_bar");
            reloadBarRequested = reloadStage;
        }
        if (((BossBarHudAccessor) GuiApi.bossBars(client)).lightningRod$bossBars().size() != 1) return;
        r.screenshot(client, "reload_held_cursor_" + reloadStage);
        r.marker(r.peer + ".reload-armed-" + reloadStage);
        reloadVerified = reloadStage;
    }

    @Override public void poll(Minecraft client) {
        if (reloadOptions) {
            reloadOptions = false;
            reloadConnection.send(new net.minecraft.network.protocol.common.ServerboundClientInformationPacket(client.options.buildPlayerInformation()));
        }
    }

    @Override public void connected(Minecraft client) {
        var channel = ((ClientConnectionAccessor) client.getConnection().getConnection()).lightningRod$channel();
        if (reloadFragment == null) {
            reloadFragment = new ReloadFragment(r.artifacts, r.peer);
            reloadConnection = client.getConnection().getConnection();
            channel.pipeline().addBefore("encrypt", "reload-fragment", reloadFragment);
        }
    }
    public void reconfigurationEncoded() {
        if (reloadFragment != null) {
            reloadFragment.capture = true;
            reloadOptions = true;
        }
    }
    static final class ReloadFragment extends ChannelOutboundHandlerAdapter {
        private record Write(ByteBuf bytes, ChannelPromise promise) {}
        private final ArrayDeque<Write> pending = new ArrayDeque<>();
        private final Path artifacts;
        private final String peer;
        private Write acknowledgement;
        private int generation;
        private int retained;
        boolean capture;
        private boolean holding;

        ReloadFragment(Path artifacts, String peer) {
            this.artifacts = artifacts;
            this.peer = peer;
        }

        @Override public void handlerAdded(ChannelHandlerContext ctx) {
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
                Files.writeString(artifacts.resolve(peer + ".reload-fragment-" + generation), "ciphertext prefix sent\n");
                poll(ctx);
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

        private void poll(ChannelHandlerContext ctx) {
            ctx.executor().schedule(() -> {
                if (!ctx.channel().isActive()) return;
                if (Files.exists(artifacts.resolve("reload-release-" + generation))) {
                    holding = false;
                    while (!pending.isEmpty()) {
                        Write write = pending.remove();
                        ctx.write(write.bytes, write.promise);
                    }
                    retained = 0;
                    ctx.flush();
                } else poll(ctx);
            }, 10, TimeUnit.MILLISECONDS);
        }
    }

}
