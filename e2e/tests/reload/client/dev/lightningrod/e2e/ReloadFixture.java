package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket;
import net.minecraft.util.Mth;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;

final class ReloadFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private enum Trigger { COMMAND, UNKNOWN_METADATA, SIGNAL }
    private enum Cursor { HELD, SWAPPED_HELD, DELETED, CATALOG }
    private enum Outcome { REJECTED, ROLLED_BACK, SUCCEEDED }
    private enum Case {
        MISSING_TARGET(Trigger.COMMAND, Cursor.HELD, Outcome.REJECTED),
        INVALID_TARGET(Trigger.COMMAND, Cursor.HELD, Outcome.ROLLED_BACK),
        PLAYER_RELOAD(Trigger.COMMAND, Cursor.SWAPPED_HELD, Outcome.SUCCEEDED),
        REPEATED_PLAYER_RELOAD(Trigger.COMMAND, Cursor.HELD, Outcome.SUCCEEDED),
        UNKNOWN_METADATA(Trigger.UNKNOWN_METADATA, Cursor.DELETED, Outcome.SUCCEEDED),
        SIGNAL(Trigger.SIGNAL, Cursor.CATALOG, Outcome.SUCCEEDED);

        final Trigger trigger;
        final Cursor cursor;
        final Outcome outcome;
        Case(Trigger trigger, Cursor cursor, Outcome outcome) {
            this.trigger = trigger;
            this.cursor = cursor;
            this.outcome = outcome;
        }
        String label() { return name().toLowerCase(java.util.Locale.ROOT); }
    }
    private static final Case[] REQUESTS = Case.values();
    private static final Case[] ROUNDS = java.util.Arrays.stream(REQUESTS)
        .filter(test -> test.outcome != Outcome.REJECTED).toArray(Case[]::new);
    private ReloadFragment reloadFragment;
    private net.minecraft.network.Connection reloadConnection;
    private volatile boolean reloadOptions;
    private int generation;
    private int requestIndex;
    private boolean reloadPositioned;
    private int reloadVerified = -1;
    private int reloadBarRequested = -1;
    private int reloadRestoreRequested = -1;
    private double reloadX;
    private double reloadZ;
    private volatile int requestedMessages;
    private volatile int successfulMessages;
    private volatile int rollbackMessages;
    private volatile int rejectedMessages;
    private volatile boolean invalidFeedback;
    private int cursorStage = -1;
    private long inventoryMismatchTick = -1;

    ReloadFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    @Override void chat(String text) {
        super.chat(text);
        if (text.equals("Reload requested.")) requestedMessages++;
        else if (text.matches("Reload successful \\(\\d+ ms\\)\\.")) successfulMessages++;
        else if (text.matches("Reload failed; rolled back successfully \\(\\d+ ms\\)\\.")) rollbackMessages++;
        else if (text.matches("Reload rejected; server unchanged \\(\\d+ ms\\)\\.")) {
            rejectedMessages++;
            if (r.peer.equals("alice")) r.marker("reload-rejected");
        } else if (text.startsWith("Reload ")) invalidFeedback = true;
        if (r.peer.equals("alice") && successfulMessages + rollbackMessages + rejectedMessages > requestedMessages) invalidFeedback = true;
        if (!r.peer.equals("alice") && requestedMessages != 0) invalidFeedback = true;
    }

    public void tick(Minecraft game, int loaded, int missing) {
        if (invalidFeedback) { client.fail("invalid_reload_feedback_or_order"); return; }
        if (loaded < 9 || game.player == null) return;
        if (r.peer.equals("alice") && requestIndex < REQUESTS.length) {
            Case request = REQUESTS[requestIndex];
            if (Files.exists(r.artifacts.resolve("reload-request-" + request.label()))) {
                switch (request.trigger) {
                    case COMMAND -> game.getConnection().sendCommand("reload");
                    case UNKNOWN_METADATA -> client.send("reload_opaque");
                    case SIGNAL -> client.send("reload_signal");
                }
                requestIndex++;
            }
        }
        Case round = generation < ROUNDS.length ? ROUNDS[generation] : null;
        if (r.joins == generation + 2) {
            if (GuiApi.screen(game) != null) return;
            if (reloadRestoreRequested != generation) {
                client.fence("reload-return-" + generation);
                reloadRestoreRequested = generation;
            }
            if (!client.fenced("reload-return-" + generation)) return;
        }
        var stack = game.player.getInventory().getItem(0);
        var cursor = game.player.containerMenu.getCarried();
        int bread = (stack.is(net.minecraft.world.item.Items.BREAD) ? stack.getCount() : 0)
            + (cursor.is(net.minecraft.world.item.Items.BREAD) ? cursor.getCount() : 0);
        boolean deletedCursor = game.player.hasInfiniteMaterials() && round != null && round.cursor == Cursor.DELETED
            && cursorStage == generation && r.joins == generation + 1;
        if (bread != (deletedCursor ? 0 : BREAD_COUNT)) {
            if (inventoryMismatchTick < 0) inventoryMismatchTick = r.tick;
            if (cursorStage >= 0 && r.tick - inventoryMismatchTick >= 40) {
                client.event("reload_inventory_mismatch", "joins", r.joins, "stage", generation,
                    "slot", stack.toString(), "cursor", cursor.toString());
                client.fail("reload_inventory_lost_or_duplicated");
            }
            return;
        }
        inventoryMismatchTick = -1;
        if (r.joins == generation + 2) {
            if (game.player.getInventory().getSelectedSlot() != selectedSlot()) {
                client.fail("reload_selected_slot_not_restored");
                return;
            }
            if (stack.getCount() != BREAD_COUNT || !cursor.isEmpty()) {
                client.event("reload_cursor_mismatch", "slot", stack.toString(), "cursor", cursor.toString());
                client.fail("reload_cursor_not_returned_to_inventory");
                return;
            }
            for (int slot = 1; slot < game.player.getInventory().getContainerSize(); slot++) {
                if (!game.player.getInventory().getItem(slot).isEmpty()) {
                    client.fail("reload_created_extra_inventory_stack_" + slot);
                    return;
                }
            }
            if (!close(game.player.getX(), reloadX, 0.01) || !close(game.player.getZ(), reloadZ, 0.01)) {
                client.fail("reload_position_not_restored");
                return;
            }
            int expectedBars = round.outcome == Outcome.ROLLED_BACK ? 1 : 0;
            if (((BossBarHudAccessor) GuiApi.bossBars(game)).lightningRod$bossBars().size() != expectedBars) {
                client.fail("reload_bossbar_state_incorrect");
                return;
            }
            if (!client.screenshot("reload_return_" + round.label()).done()) return;
            client.send("reload_selection");
            generation++;
            round = generation < ROUNDS.length ? ROUNDS[generation] : null;
            reloadPositioned = false;
            client.event("reload_return", "generation", generation, "joins", r.joins);
        }
        if (r.joins != generation + 1) { client.fail("unexpected_reload_join_count"); return; }
        if (!reloadPositioned && GuiApi.screen(game) == null) {
            if (game.level.players().size() != 2) return;
            reloadX = (r.peer.equals("alice") ? -3.5 : 3.5) + generation;
            reloadZ = 3.5 + generation;
            game.player.getInventory().setSelectedSlot(selectedSlot());
            game.getConnection().send(new ServerboundSetCarriedItemPacket(selectedSlot()));
            game.player.setPos(reloadX, 65, reloadZ);
            game.player.setYRot(r.peer.equals("alice") ? -90 : 90);
            game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(reloadX, 65, reloadZ, game.player.getYRot(), 0, true, false));
            game.getConnection().sendChat(r.peer + " reload " + generation);
            reloadPositioned = true;
            client.fence("reload-move-" + generation);
        }
        if (!reloadPositioned || !client.fenced("reload-move-" + generation) || reloadVerified == generation) return;
        String otherName = r.peer.equals("alice") ? "bob" : "alice";
        var other = game.level.players().stream().filter(p -> p.getName().getString().equals(otherName)).findFirst().orElse(null);
        if (other == null || game.level.players().size() != 2 || game.getConnection().getOnlinePlayers().size() != 2) return;
        double expectedX = (otherName.equals("alice") ? -3.5 : 3.5) + generation;
        if (!close(other.getX(), expectedX, 0.1) || !close(other.getZ(), 3.5 + generation, 0.1)
            || !close(Mth.wrapDegrees(other.getYHeadRot() - (otherName.equals("alice") ? -90 : 90)), 0, 2)) return;
        if (!r.receivedChat.contains("<" + otherName + "> " + otherName + " reload " + generation)) return;
        if (generation == ROUNDS.length) {
            if (r.peer.equals("alice") && (requestedMessages != commandCount(null) || successfulMessages != commandCount(Outcome.SUCCEEDED)
                || rollbackMessages != commandCount(Outcome.ROLLED_BACK) || rejectedMessages != commandCount(Outcome.REJECTED))) return;
            if (r.peer.equals("bob") && (requestedMessages != 0 || successfulMessages != 1 || rollbackMessages != 0 || rejectedMessages != 0)) return;
            if (missingChunks(game, r.minimumRadius) != 0 || !game.player.onGround() || !close(game.player.getY(), 65, 0.01)) return;
            if (reloadFragment == null || reloadFragment.generation != ROUNDS.length || reloadFragment.released != ROUNDS.length) {
                client.fail("reload_fragment_not_exercised");
                return;
            }
            if (!client.screenshot("reload_feedback").done()) return;
            client.pass("reload_player_signal_and_unknown_metadata_verified");
            return;
        }
        if (cursorStage != generation) {
            if (!client.screenshot("reload_visible_peers_" + round.label()).done()) return;
            if (game.player.hasInfiniteMaterials()) {
                var screen = new CreativeInventory(game);
                GuiApi.screen(game, screen);
                screen.inventoryTab();
                if (round.cursor == Cursor.SWAPPED_HELD || round.cursor == Cursor.CATALOG) {
                    screen.pickSlot(36);
                    screen.pickSlot(37);
                    screen.pickSlot(37);
                    screen.pickSlot(36);
                }
                if (round.cursor != Cursor.CATALOG) screen.pickSlot(36);
                if (round.cursor == Cursor.DELETED) screen.pickSlot(46);
                if (round.cursor == Cursor.CATALOG) {
                    screen.catalogTab();
                    screen.pickSlot(0);
                }
            } else {
                GuiApi.screen(game, new InventoryScreen(game.player));
                GameApi.inventoryClick(game, 36, 0, ClickType.PICKUP);
            }
            cursorStage = generation;
            client.fence("reload-cursor-" + generation);
            return;
        }
        if (!client.fenced("reload-cursor-" + generation)) return;
        boolean returnedCursor = game.player.hasInfiniteMaterials() && round.cursor == Cursor.CATALOG;
        int expectedSlot = returnedCursor ? BREAD_COUNT : 0;
        int expectedCursor = deletedCursor ? 0 : BREAD_COUNT;
        if (returnedCursor) {
            if (cursor.isEmpty() || cursor.is(net.minecraft.world.item.Items.BREAD)) {
                client.fail("reload_catalog_cursor_setup_failed");
                return;
            }
            expectedCursor = cursor.getCount();
        }
        if (game.player.getInventory().getItem(0).getCount() != expectedSlot || cursor.getCount() != expectedCursor) {
            client.fail("reload_cursor_setup_failed");
            return;
        }
        if (round == Case.INVALID_TARGET) {
            r.marker(r.peer + ".reload-ready");
            if (!Files.exists(r.artifacts.resolve("reload-rejected"))) return;
        }
        if (reloadBarRequested != generation) {
            client.send("reload_bar");
            reloadBarRequested = generation;
        }
        if (((BossBarHudAccessor) GuiApi.bossBars(game)).lightningRod$bossBars().size() != 1) return;
        if (!client.screenshot("reload_held_cursor_" + round.label()).done()) return;
        r.marker(r.peer + ".reload-armed-" + round.label());
        reloadVerified = generation;
    }

    private int selectedSlot() { return r.peer.equals("alice") ? 4 : 7; }

    private static int commandCount(Outcome outcome) {
        return (int) java.util.Arrays.stream(REQUESTS)
            .filter(test -> test.trigger == Trigger.COMMAND && (outcome == null || test.outcome == outcome)).count();
    }

    @Override public void poll(Minecraft game) {
        if (reloadOptions) {
            reloadOptions = false;
            reloadConnection.send(new net.minecraft.network.protocol.common.ServerboundClientInformationPacket(game.options.buildPlayerInformation()));
        }
    }

    @Override public void connected(Minecraft game) {
        var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        if (reloadFragment == null) {
            reloadFragment = new ReloadFragment(r.artifacts, r.peer);
            reloadConnection = game.getConnection().getConnection();
            channel.pipeline().addBefore("encrypt", "reload-fragment", reloadFragment);
            channel.pipeline().addBefore("packet_handler", "reload-resumption", new ChannelInboundHandlerAdapter() {
                @Override public void channelRead(ChannelHandlerContext ctx, Object message) throws Exception {
                    // Configuration data is sent after the parked session resumes.
                    if (message instanceof net.minecraft.network.protocol.configuration.ClientboundUpdateEnabledFeaturesPacket)
                        reloadFragment.resumed();
                    ctx.fireChannelRead(message);
                }
            });
        }
    }
    public void reconfigurationEncoded() {
        if (reloadFragment != null) {
            reloadFragment.capture = true;
            reloadOptions = true;
        }
    }
}
