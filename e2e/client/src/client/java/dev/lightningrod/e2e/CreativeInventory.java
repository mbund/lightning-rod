package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.CreativeModeTab;

final class CreativeInventory extends CreativeModeInventoryScreen {
    CreativeInventory(Minecraft game) {
        super(game.player, game.player.connection.enabledFeatures(), false);
    }

    void inventoryTab() {
        selectTab(CreativeModeTab.Type.INVENTORY);
    }

    void catalogTab() {
        selectTab(CreativeModeTab.Type.CATEGORY);
    }

    private void selectTab(CreativeModeTab.Type type) {
        var tab = BuiltInRegistries.CREATIVE_MODE_TAB.stream().filter(group -> group.getType() == type).findFirst().orElseThrow();
        for (int px = 0; px < imageWidth; px += 4) {
            for (int py = -32; py < imageHeight + 32; py += 4) {
                if (!checkTabClicked(tab, px, py)) continue;
                ClientApi.click(this, leftPos + px, topPos + py);
                if (isInventoryOpen() != (type == CreativeModeTab.Type.INVENTORY)) throw new IllegalStateException("creative tab not selected");
                return;
            }
        }
        throw new IllegalStateException("creative inventory tab not found");
    }

    void click(int slot, int button, ClickType type) {
        if (!isInventoryOpen() && slot >= 36 && slot < 45) slot += 9;
        slotClicked(slot < 0 ? null : menu.slots.get(slot), slot, button, GameApi.click(type));
    }

    void pickSlot(int slot) { click(slot, 0, ClickType.PICKUP); }
}
