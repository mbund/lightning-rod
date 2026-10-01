package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.resources.Identifier;

final class GameApi {
    static long dayTime(Minecraft client) { return client.level.getDayTime(); }
    static void inventoryClick(Minecraft client, int slot, int button, ClickType type) {
        client.gameMode.handleInventoryMouseClick(0, slot, button, click(type), client.player);
    }
    static Identifier id(String path) { return Identifier.withDefaultNamespace(path); }
    static String dimension(Minecraft client) { return client.level.dimension().identifier().toString(); }
    static net.minecraft.world.inventory.ClickType click(ClickType type) {
        return net.minecraft.world.inventory.ClickType.valueOf(type.name());
    }
}
