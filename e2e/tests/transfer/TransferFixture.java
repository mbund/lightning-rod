package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.ServerStatusPinger;

final class TransferFixture extends Fixture {
    private boolean readyPublished;
    private int transferStage = -1;
    private long returnTick = -1;
    private final ServerStatusPinger pinger = new ServerStatusPinger();
    private ServerData status;

    TransferFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    public void tick(Minecraft client, int loaded, int missing) {
        if (loaded < 9 || client.getConnection() == null) return;
        if (client.level.players().size() != 1 || client.getConnection().getOnlinePlayers().size() != 1) {
            r.fail(client, "transfer_player_list_leaked");
            return;
        }
        var stack = client.player.getInventory().getItem(0);
        if (r.peer.equals("bob")) {
            if (!readyPublished) {
                r.marker("transfer-bob-ready");
                readyPublished = true;
            }
            if (r.joins != 1 || !stack.isEmpty()) r.fail(client, "unrelated_simulation_changed");
            else if (Files.exists(r.artifacts.resolve("transfer-complete"))) r.pass(client, "unrelated_simulation_preserved");
            return;
        }
        if (transferStage == -1 && stack.is(net.minecraft.world.item.Items.BREAD) && stack.getCount() == 17 && Files.exists(r.artifacts.resolve("transfer-bob-ready"))) {
            if (status == null) {
                status = new ServerData("Islands", r.server, ServerData.Type.OTHER);
                try { StatusApi.ping(pinger, status); }
                catch (java.net.UnknownHostException error) { r.fail(client, "status_dns_failed"); }
                return;
            }
            pinger.tick();
            if (status.players == null) return;
            if (status.players.online() != 2 || status.players.max() != 2 || !status.motd.getString().equals("E2E islands")) {
                r.fail(client, "island_status_incorrect");
                return;
            }
            pinger.removeAll();
            client.getConnection().sendCommand("transfer_full");
            transferStage = 0;
        } else if (transferStage == 0 && r.receivedChat.contains("Destination full") && stack.is(net.minecraft.world.item.Items.BREAD) && stack.getCount() == 17) {
            if (r.joins != 1) { r.fail(client, "full_destination_changed_connection"); return; }
            GuiApi.screen(client, new net.minecraft.client.gui.screens.inventory.InventoryScreen(client.player));
            r.screenshot(client, "transfer_source_inventory");
            client.getConnection().sendCommand("transfer");
            transferStage = 1;
        } else if (transferStage == 1 && r.joins == 2 && GuiApi.screen(client) == null) {
            if (!stack.isEmpty()) { r.fail(client, "destination_inventory_leaked"); return; }
            r.screenshot(client, "transfer_destination");
            client.getConnection().sendCommand("transfer");
            transferStage = 2;
        } else if (transferStage == 2 && r.joins == 3 && GuiApi.screen(client) == null) {
            if (returnTick < 0) returnTick = r.tick;
            if (!stack.is(net.minecraft.world.item.Items.BREAD) || stack.getCount() != 17) {
                if (r.tick - returnTick < 100) return;
                r.fail(client, "source_inventory_lost_or_duplicated");
                return;
            }
            r.screenshot(client, "transfer_return");
            r.marker("transfer-complete");
            r.pass(client, "transfer_round_trip_preserved_independent_state");
        }
    }

}
