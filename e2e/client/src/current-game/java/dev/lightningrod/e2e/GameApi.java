package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.resources.Identifier;

final class GameApi {
    static long dayTime(Minecraft client) { return client.level.getOverworldClockTime(); }
    static void inventoryClick(Minecraft client, int slot, int button, ClickType type) {
        client.gameMode.handleContainerInput(client.player.containerMenu.containerId, slot, button, click(type), client.player);
    }
    static Identifier fixtureChannel() { return Identifier.fromNamespaceAndPath("lightning_rod", "e2e"); }
    static Identifier id(String path) { return Identifier.withDefaultNamespace(path); }
    static String dimension(Minecraft client) { return client.level.dimension().identifier().toString(); }
    static net.minecraft.world.inventory.ContainerInput click(ClickType type) {
        return net.minecraft.world.inventory.ContainerInput.valueOf(type.name());
    }
}
