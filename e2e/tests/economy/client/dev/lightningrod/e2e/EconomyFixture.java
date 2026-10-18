package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class EconomyFixture extends Fixture {
    private enum Phase { BUY, SELL, REJECT_SALE, REJECT_PURCHASE, PAY, QUERY_BALANCE, COMPLETE }
    private Phase phase = Phase.BUY;
    private boolean readyPublished;

    EconomyFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || loaded < 9) return;
        if (r.scenario.equals("economy-reopen-multi")) {
            if (phase == Phase.BUY) {
                phase = Phase.SELL;
                game.getConnection().sendCommand("balance");
            }
            int bread = 0;
            for (int slot = 0; slot < game.player.getInventory().getContainerSize(); slot++) {
                var stack = game.player.getInventory().getItem(slot);
                if (stack.is(net.minecraft.world.item.Items.BREAD)) bread += stack.getCount();
            }
            if (r.receivedChat.contains(r.peer.equals("alice") ? "7.800 credit" : "11.000 credit")
                && bread == (r.peer.equals("alice") ? 1 : 0)) {
                if (!client.screenshot("durable_items_and_balance").done()) return;
                client.pass("items_and_balances_survive_reopen");
            }
            return;
        }
        if (!readyPublished) {
            client.mark(r.peer + ".economy-ready");
            readyPublished = true;
        }
        if (!r.expectedPeers.stream().allMatch(name -> client.marked(name + ".economy-ready"))) return;
        String command = null;
        if (r.peer.equals("bob")) {
            if (phase == Phase.BUY && client.marked("payment-complete")) {
                command = "balance";
            } else if (phase == Phase.COMPLETE && r.receivedChat.contains("11.000 credit")) {
                if (!client.screenshot("recipient_balance").done()) return;
                client.pass("payment_credited_once");
            }
        } else {
            int bread = 0;
            for (int slot = 0; slot < game.player.getInventory().getContainerSize(); slot++) {
                var stack = game.player.getInventory().getItem(slot);
                if (stack.is(net.minecraft.world.item.Items.BREAD)) bread += stack.getCount();
            }
            if (phase == Phase.BUY) command = "buy bread 2";
            else if (phase == Phase.SELL && r.receivedChat.contains("Purchase complete") && bread == 2) command = "sell bread 1";
            else if (phase == Phase.REJECT_SALE && r.receivedChat.contains("Sale complete") && bread == 1) command = "sell bread 2";
            else if (phase == Phase.REJECT_PURCHASE && r.receivedChat.contains("Insufficient matching items") && bread == 1) command = "buy bread 65535";
            else if (phase == Phase.PAY && r.receivedChat.contains("Insufficient funds or balance limit reached") && bread == 1) command = "pay bob 1.000";
            else if (phase == Phase.QUERY_BALANCE && r.receivedChat.contains("7.800 credit") && bread == 1) command = "balance";
            else if (phase == Phase.COMPLETE && r.receivedChat.contains("7.800 credit") && bread == 1) {
                client.mark("payment-complete");
                if (!client.screenshot("purchase_sale_and_payment").done()) return;
                client.pass("trades_and_rejections_preserve_items_and_money");
            }
        }
        if (command != null) {
            r.receivedChat.clear();
            phase = r.peer.equals("bob") ? Phase.COMPLETE : switch (phase) {
                case BUY -> Phase.SELL;
                case SELL -> Phase.REJECT_SALE;
                case REJECT_SALE -> Phase.REJECT_PURCHASE;
                case REJECT_PURCHASE -> Phase.PAY;
                case PAY -> Phase.QUERY_BALANCE;
                case QUERY_BALANCE -> Phase.COMPLETE;
                case COMPLETE -> throw new IllegalStateException("economy already complete");
            };
            game.getConnection().sendCommand(command);
            client.event("economy_command", "command", command);
        }
    }

}
