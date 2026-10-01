package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;

final class EconomyFixture extends Fixture {
    private int economyStage;
    private boolean readyPublished;

    EconomyFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || loaded < 9) return;
        if (r.scenario.equals("economy-reopen-multi")) {
            if (economyStage == 0) {
                economyStage = 1;
                client.getConnection().sendCommand("balance");
            }
            int bread = 0;
            for (int slot = 0; slot < client.player.getInventory().getContainerSize(); slot++) {
                var stack = client.player.getInventory().getItem(slot);
                if (stack.is(net.minecraft.world.item.Items.BREAD)) bread += stack.getCount();
            }
            if (r.receivedChat.contains(r.peer.equals("alice") ? "7.800 credit" : "11.000 credit")
                && bread == (r.peer.equals("alice") ? 1 : 0)) {
                r.screenshot(client, "durable_items_and_balance");
                r.pass(client, "items_and_balances_survive_reopen");
            }
            return;
        }
        if (!readyPublished) {
            r.marker(r.peer + ".economy-ready");
            readyPublished = true;
        }
        if (!r.expectedPeers.stream().allMatch(name -> Files.exists(r.artifacts.resolve(name + ".economy-ready")))) return;
        String command = null;
        if (r.peer.equals("bob")) {
            if (economyStage == 0 && Files.exists(r.artifacts.resolve("payment-complete"))) {
                command = "balance";
            } else if (economyStage == 1 && r.receivedChat.contains("11.000 credit")) {
                r.screenshot(client, "recipient_balance");
                r.pass(client, "payment_credited_once");
            }
        } else {
            int bread = 0;
            for (int slot = 0; slot < client.player.getInventory().getContainerSize(); slot++) {
                var stack = client.player.getInventory().getItem(slot);
                if (stack.is(net.minecraft.world.item.Items.BREAD)) bread += stack.getCount();
            }
            if (economyStage == 0) command = "buy bread 2";
            else if (economyStage == 1 && r.receivedChat.contains("Purchase complete") && bread == 2) command = "sell bread 1";
            else if (economyStage == 2 && r.receivedChat.contains("Sale complete") && bread == 1) command = "sell bread 2";
            else if (economyStage == 3 && r.receivedChat.contains("Insufficient matching items") && bread == 1) command = "buy bread 65535";
            else if (economyStage == 4 && r.receivedChat.contains("Insufficient funds or balance limit reached") && bread == 1) command = "pay bob 1.000";
            else if (economyStage == 5 && r.receivedChat.contains("7.800 credit") && bread == 1) command = "balance";
            else if (economyStage == 6 && r.receivedChat.contains("7.800 credit") && bread == 1) {
                r.marker("payment-complete");
                r.screenshot(client, "purchase_sale_and_payment");
                r.pass(client, "trades_and_rejections_preserve_items_and_money");
            }
        }
        if (command != null) {
            r.receivedChat.clear();
            economyStage++;
            client.getConnection().sendCommand(command);
            r.event("economy_command", "command", command);
        }
    }

}
