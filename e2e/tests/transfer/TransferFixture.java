package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.screen.ingame.InventoryScreen;

final class TransferFixture extends Fixture {
    private boolean readyPublished;
    private int transferStage = -1;

    TransferFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (loaded < 9 || client.getNetworkHandler() == null) return;
        if (client.world.getPlayers().size() != 1 || client.getNetworkHandler().getPlayerList().size() != 1) {
            r.fail(client, "transfer_player_list_leaked");
            return;
        }
        var stack = client.player.getInventory().getStack(0);
        if (r.peer.equals("bob")) {
            if (!readyPublished) {
                r.marker("transfer-bob-ready");
                readyPublished = true;
            }
            if (r.joins != 1 || !stack.isEmpty()) r.fail(client, "unrelated_simulation_changed");
            else if (Files.exists(r.artifacts.resolve("transfer-complete"))) r.pass(client, "unrelated_simulation_preserved");
            return;
        }
        if (transferStage == -1 && stack.isOf(net.minecraft.item.Items.BREAD) && stack.getCount() == 17 && Files.exists(r.artifacts.resolve("transfer-bob-ready"))) {
            client.getNetworkHandler().sendChatCommand("transfer_full");
            transferStage = 0;
        } else if (transferStage == 0 && r.receivedChat.contains("Destination full") && stack.isOf(net.minecraft.item.Items.BREAD) && stack.getCount() == 17) {
            if (r.joins != 1) { r.fail(client, "full_destination_changed_connection"); return; }
            client.setScreen(new net.minecraft.client.gui.screen.ingame.InventoryScreen(client.player));
            r.screenshot(client, "transfer_source_inventory");
            client.getNetworkHandler().sendChatCommand("transfer");
            transferStage = 1;
        } else if (transferStage == 1 && r.joins == 2 && client.currentScreen == null) {
            if (!stack.isEmpty()) { r.fail(client, "destination_inventory_leaked"); return; }
            r.screenshot(client, "transfer_destination");
            client.getNetworkHandler().sendChatCommand("transfer");
            transferStage = 2;
        } else if (transferStage == 2 && r.joins == 3 && client.currentScreen == null) {
            if (!stack.isOf(net.minecraft.item.Items.BREAD) || stack.getCount() != 17) {
                r.fail(client, "source_inventory_lost_or_duplicated");
                return;
            }
            r.screenshot(client, "transfer_return");
            r.marker("transfer-complete");
            r.pass(client, "transfer_round_trip_preserved_independent_state");
        }
    }

}
