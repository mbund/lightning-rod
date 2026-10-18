package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.ServerStatusPinger;

final class TransferFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private boolean readyPublished;
    private enum Phase { STATUS, FULL, DESTINATION, RETURN }
    private Phase phase = Phase.STATUS;
    private long returnTick = -1;
    private final ServerStatusPinger pinger = new ServerStatusPinger();
    private ServerData status;

    TransferFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    public void tick(Minecraft game, int loaded, int missing) {
        if (loaded < 9 || game.getConnection() == null) return;
        if (game.level.players().size() != 1 || game.getConnection().getOnlinePlayers().size() != 1) {
            client.fail("transfer_player_list_leaked");
            return;
        }
        var stack = game.player.getInventory().getItem(0);
        if (r.peer.equals("bob")) {
            if (!readyPublished) {
                r.marker("transfer-bob-ready");
                readyPublished = true;
            }
            if (r.joins != 1 || !stack.isEmpty()) client.fail("unrelated_simulation_changed");
            else if (Files.exists(r.artifacts.resolve("transfer-complete"))) client.pass("unrelated_simulation_preserved");
            return;
        }
        if (phase == Phase.STATUS && stack.is(net.minecraft.world.item.Items.BREAD) && stack.getCount() == BREAD_COUNT && Files.exists(r.artifacts.resolve("transfer-bob-ready"))) {
            if (status == null) {
                status = new ServerData("Islands", r.server, ServerData.Type.OTHER);
                try { StatusApi.ping(pinger, status); }
                catch (java.net.UnknownHostException error) { client.fail("status_dns_failed"); return; }
                return;
            }
            pinger.tick();
            if (status.players == null) return;
            if (status.players.online() != 2 || status.players.max() != 2 || !status.motd.getString().equals("E2E islands")) {
                client.fail("island_status_incorrect");
                return;
            }
            pinger.removeAll();
            client.send("transfer_full");
            phase = Phase.FULL;
        } else if (phase == Phase.FULL && client.received("Destination full") && stack.is(net.minecraft.world.item.Items.BREAD) && stack.getCount() == BREAD_COUNT) {
            if (r.joins != 1) { client.fail("full_destination_changed_connection"); return; }
            GuiApi.screen(game, new net.minecraft.client.gui.screens.inventory.InventoryScreen(game.player));
            if (!client.screenshot("transfer_source_inventory").done()) return;
            client.send("transfer");
            phase = Phase.DESTINATION;
        } else if (phase == Phase.DESTINATION && r.joins == 2 && GuiApi.screen(game) == null) {
            if (!stack.isEmpty()) { client.fail("destination_inventory_leaked"); return; }
            if (!client.screenshot("transfer_destination").done()) return;
            client.send("transfer");
            phase = Phase.RETURN;
        } else if (phase == Phase.RETURN && r.joins == 3 && GuiApi.screen(game) == null) {
            if (returnTick < 0) returnTick = r.tick;
            if (!stack.is(net.minecraft.world.item.Items.BREAD) || stack.getCount() != BREAD_COUNT) {
                if (r.tick - returnTick < 100) return;
                client.fail("source_inventory_lost_or_duplicated");
                return;
            }
            if (!client.screenshot("transfer_return").done()) return;
            r.marker("transfer-complete");
            client.pass("transfer_round_trip_preserved_independent_state");
        }
    }

}
