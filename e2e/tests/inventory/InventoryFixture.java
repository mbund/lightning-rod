package dev.lightningrod.e2e;

import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.screen.ingame.InventoryScreen;
import net.minecraft.screen.slot.SlotActionType;

final class InventoryFixture extends Fixture {
    private long inventoryTick = -1;
    private int inventoryRevision;
    private boolean inventoryRequested;
    private boolean inventoryPickupSent;
    private boolean inventoryPlaceSent;

    InventoryFixture(Recorder r) { super(r); }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (!inventoryRequested && !client.player.getInventory().getStack(0).isEmpty()) {
            inventoryRequested = true;
            inventoryTick = r.tick;
            inventoryRevision = client.player.currentScreenHandler.getRevision();
            client.setScreen(new InventoryScreen(client.player));
            r.screenshot(client, "inventory_opened");
        }
        if (!inventoryRequested || r.tick - inventoryTick < 5) return;
        if (!(client.currentScreen instanceof InventoryScreen)) {
            r.fail(client, "inventory_not_open");
            return;
        }
        int syncId = client.player.currentScreenHandler.syncId;
        if (!inventoryPickupSent) {
            inventoryPickupSent = true;
            client.interactionManager.clickSlot(syncId, 36, 0, SlotActionType.PICKUP, client.player);
            r.event("inventory_pickup_sent", "slot", 36);
            return;
        }
        if (!inventoryPlaceSent && r.tick - inventoryTick >= 10) {
            inventoryPlaceSent = true;
            client.interactionManager.clickSlot(syncId, 37, 0, SlotActionType.PICKUP, client.player);
            r.event("inventory_place_sent", "slot", 37);
            return;
        }
        if (inventoryPlaceSent && r.tick - inventoryTick >= 20) {
            if (client.player.getInventory().getStack(0).isEmpty()
                && client.player.currentScreenHandler.getRevision() >= inventoryRevision + 2
                && client.player.getInventory().getStack(1).isOf(net.minecraft.item.Items.BREAD)
                && client.player.getInventory().getStack(1).getCount() == 17
                && client.player.currentScreenHandler.getCursorStack().isEmpty()) {
                r.screenshot(client, "inventory_transaction_applied");
                r.pass(client, "inventory_slot_transaction_applied");
            } else {
                r.fail(client, "inventory_slot_transaction_rejected");
            }
        }
    }

}
