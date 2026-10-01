package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.resources.ResourceLocation;

final class GameApi {
    static long dayTime(Minecraft client) { return client.level.getDayTime(); }
    static void inventoryClick(Minecraft client, int slot, int button, ClickType type) {
        client.gameMode.handleInventoryMouseClick(0, slot, button, click(type), client.player);
    }
    static ResourceLocation id(String path) { return ResourceLocation.withDefaultNamespace(path); }
    static String dimension(Minecraft client) { return client.level.dimension().location().toString(); }
    static net.minecraft.world.inventory.ClickType click(ClickType type) {
        return net.minecraft.world.inventory.ClickType.valueOf(type.name());
    }
}
