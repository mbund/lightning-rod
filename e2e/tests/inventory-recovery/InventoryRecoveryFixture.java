package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.item.Items;

final class InventoryRecoveryFixture extends Fixture {
    private int step;
    private long ready;

    InventoryRecoveryFixture(Recorder recorder) { super(recorder); }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (client.player == null || r.terrainTick < 0 || System.nanoTime() < ready) return;
        boolean seed = r.scenario.endsWith("-seed");
        if (step == 0) {
            if (seed) client.getConnection().sendCommand("inventory_setup recovery 9/minecraft:diamond/13 36/minecraft:bread/17");
            step++;
            ready = System.nanoTime() + 500_000_000L;
            return;
        }
        if (step == 1) {
            if (seed && !r.receivedChat.contains("Inventory recovery ready")) return;
            var handler = client.player.inventoryMenu;
            for (int slot = 0; slot < 46; slot++) {
                var stack = handler.getSlot(slot).getItem();
                boolean valid = slot == 9 ? stack.is(Items.DIAMOND) && stack.getCount() == 13
                    : slot == 36 ? stack.is(Items.BREAD) && stack.getCount() == 17 : stack.isEmpty();
                if (!valid) { r.fail(client, "recovery_slot_" + slot + "_" + stack); return; }
            }
            if (!handler.getCarried().isEmpty()) { r.fail(client, "recovery_cursor_not_cleared"); return; }
            if (!client.player.hasInfiniteMaterials()) { r.fail(client, "recovery_requires_creative"); return; }
            var screen = new InventoryFixture.CreativeScreen(client);
            GuiApi.screen(client, screen);
            screen.inventoryTab();
            if (seed) screen.pickSlot(9);
            step++;
            ready = System.nanoTime() + 500_000_000L;
            return;
        }
        if (step == 2) {
            if (seed && (client.player.containerMenu.getCarried().getCount() != 13
                || !client.player.inventoryMenu.getSlot(9).getItem().isEmpty())) {
                r.fail(client, "recovery_pickup_failed");
                return;
            }
            client.getConnection().sendCommand(seed
                ? "inventory_check recovery 36/minecraft:bread/17 pending/minecraft:diamond/13"
                : "inventory_check recovery 9/minecraft:diamond/13 36/minecraft:bread/17 pending/empty/0");
            step++;
            return;
        }
        if (step == 3) {
            if (r.receivedChat.contains("Inventory recovery mismatch")) { r.fail(client, "recovery_server_state_mismatch"); return; }
            if (!r.receivedChat.contains("Inventory recovery verified")) return;
            // Give the asynchronous durability writer time to finish before the intentional crash.
            ready = System.nanoTime() + 2_000_000_000L;
            step++;
            return;
        }
        r.screenshot(client, seed ? "recovery_held_before_stop" : "recovery_restored");
        r.pass(client, seed ? "recovery_record_seeded" : "recovery_restored_once_without_duplication");
    }
}
