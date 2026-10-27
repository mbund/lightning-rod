package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.world.item.Items;

final class InventoryRecoveryFixture extends Fixture {
    private enum Phase { SETUP, READY, PICKUP, REFRESH, CHECK, DURABLE }
    private Phase phase = Phase.SETUP;

    InventoryRecoveryFixture(Recorder recorder) { super(recorder); }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || r.terrainTick < 0) return;
        boolean seed = r.scenario.endsWith("-seed");
        boolean creative = game.player.hasInfiniteMaterials();
        if (phase == Phase.SETUP) {
            if (seed) client.send("inventory_setup cursor 9/minecraft:diamond/13 36/minecraft:bread/17");
            phase = Phase.READY;
            client.fence("cursor-setup");
            return;
        }
        if (phase == Phase.READY) {
            if (!client.fenced("cursor-setup")) return;
            if (seed && !client.received("Inventory cursor ready")) return;
            var handler = game.player.inventoryMenu;
            for (int slot = 0; slot < 46; slot++) {
                var stack = handler.getSlot(slot).getItem();
                boolean valid = (seed || !creative) && slot == (seed ? 9 : 37) ? stack.is(Items.DIAMOND) && stack.getCount() == 13
                    : slot == 36 ? stack.is(Items.BREAD) && stack.getCount() == 17 : stack.isEmpty();
                if (!valid) { client.fail("cursor_slot_" + slot + "_" + stack); return; }
            }
            if (!handler.getCarried().isEmpty()) { client.fail("cursor_not_cleared"); return; }
            if (creative) {
                var screen = new CreativeInventory(game);
                GuiApi.screen(game, screen);
                screen.inventoryTab();
                if (seed) screen.pickSlot(9);
            } else {
                GuiApi.screen(game, new InventoryScreen(game.player));
                if (seed) GameApi.inventoryClick(game, 9, 0, ClickType.PICKUP);
            }
            phase = Phase.PICKUP;
            client.fence("cursor-pickup");
            return;
        }
        if (phase == Phase.PICKUP) {
            if (!client.fenced("cursor-pickup")) return;
            if (seed && (game.player.containerMenu.getCarried().getCount() != 13
                || !game.player.inventoryMenu.getSlot(9).getItem().isEmpty())) {
                client.fail("cursor_pickup_failed");
                return;
            }
            if (seed && creative) {
                client.send("inventory_setup refresh 36/minecraft:bread/17");
                client.fence("cursor-refresh");
                phase = Phase.REFRESH;
                return;
            }
            check(seed, creative);
            return;
        }
        if (phase == Phase.REFRESH) {
            if (!client.received("Inventory refresh ready") || !client.fenced("cursor-refresh")) return;
            var held = game.player.containerMenu.getCarried();
            if (!held.is(Items.DIAMOND) || held.getCount() != 13) { client.fail("creative_refresh_overwrote_cursor"); return; }
            check(seed, creative);
            return;
        }
        if (phase == Phase.CHECK) {
            if (client.received("Inventory cursor mismatch")) { client.fail("cursor_server_state_mismatch"); return; }
            if (!client.received("Inventory cursor verified")) return;
            client.durable("cursor");
            phase = Phase.DURABLE;
            return;
        }
        if (!client.fenced("cursor")) return;
        if (!client.screenshot(seed ? "cursor_before_stop" : "inventory_after_restart").done()) return;
        client.pass(seed ? "reported_inventory_saved" : creative ? "unreported_creative_cursor_not_restored" : "survival_cursor_returned_once");
    }
    private void check(boolean seed, boolean creative) {
        String contents = "36/minecraft:bread/17";
        if (!creative) contents += seed ? " 46/minecraft:diamond/13" : " 37/minecraft:diamond/13";
        client.send("inventory_check cursor " + contents);
        phase = Phase.CHECK;
    }

}
