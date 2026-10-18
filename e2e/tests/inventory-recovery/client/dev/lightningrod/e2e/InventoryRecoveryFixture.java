package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.item.Items;

final class InventoryRecoveryFixture extends Fixture {
    private enum Phase { SETUP, READY, PICKUP, CHECK, DURABLE }
    private Phase phase = Phase.SETUP;

    InventoryRecoveryFixture(Recorder recorder) { super(recorder); }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || r.terrainTick < 0) return;
        boolean seed = r.scenario.endsWith("-seed");
        if (phase == Phase.SETUP) {
            if (seed) client.send("inventory_setup recovery 9/minecraft:diamond/13 36/minecraft:bread/17");
            phase = Phase.READY;
            client.fence("recovery-setup");
            return;
        }
        if (phase == Phase.READY) {
            if (!client.fenced("recovery-setup")) return;
            if (seed && !client.received("Inventory recovery ready")) return;
            var handler = game.player.inventoryMenu;
            for (int slot = 0; slot < 46; slot++) {
                var stack = handler.getSlot(slot).getItem();
                boolean valid = slot == 9 ? stack.is(Items.DIAMOND) && stack.getCount() == 13
                    : slot == 36 ? stack.is(Items.BREAD) && stack.getCount() == 17 : stack.isEmpty();
                if (!valid) { client.fail("recovery_slot_" + slot + "_" + stack); return; }
            }
            if (!handler.getCarried().isEmpty()) { client.fail("recovery_cursor_not_cleared"); return; }
            if (!game.player.hasInfiniteMaterials()) { client.fail("recovery_requires_creative"); return; }
            var screen = new CreativeInventory(game);
            GuiApi.screen(game, screen);
            screen.inventoryTab();
            if (seed) screen.pickSlot(9);
            phase = Phase.PICKUP;
            client.fence("recovery-pickup");
            return;
        }
        if (phase == Phase.PICKUP) {
            if (!client.fenced("recovery-pickup")) return;
            if (seed && (game.player.containerMenu.getCarried().getCount() != 13
                || !game.player.inventoryMenu.getSlot(9).getItem().isEmpty())) {
                client.fail("recovery_pickup_failed");
                return;
            }
            client.send(seed
                ? "inventory_check recovery 36/minecraft:bread/17 pending/minecraft:diamond/13"
                : "inventory_check recovery 9/minecraft:diamond/13 36/minecraft:bread/17 pending/empty/0");
            phase = Phase.CHECK;
            return;
        }
        if (phase == Phase.CHECK) {
            if (client.received("Inventory recovery mismatch")) { client.fail("recovery_server_state_mismatch"); return; }
            if (!client.received("Inventory recovery verified")) return;
            client.durable("recovery");
            phase = Phase.DURABLE;
            return;
        }
        if (!client.fenced("recovery")) return;
        if (!client.screenshot(seed ? "recovery_held_before_stop" : "recovery_restored").done()) return;
        client.pass(seed ? "recovery_record_seeded" : "recovery_restored_once_without_duplication");
    }
}
