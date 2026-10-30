package dev.lightningrod.registry;

import net.minecraft.core.RegistryAccess;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;

final class FuelApi {
    static void prepare(RegistryAccess lookup) {}
    static ItemStack remainder(Item item) { return item.getCraftingRemainder(); }
}
