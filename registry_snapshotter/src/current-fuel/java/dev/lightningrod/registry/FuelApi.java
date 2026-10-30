package dev.lightningrod.registry;

import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;

final class FuelApi {
    static void prepare(RegistryAccess lookup) {
        for (var components : BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup)) components.apply();
    }
    static ItemStack remainder(Item item) {
        var remainder = item.getCraftingRemainder();
        return remainder == null ? ItemStack.EMPTY : remainder.create();
    }
}
