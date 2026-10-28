package dev.lightningrod.registry;

import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.CraftingInput;
import net.minecraft.world.item.crafting.CraftingRecipe;
import net.minecraft.world.item.crafting.SingleRecipeInput;
import net.minecraft.world.item.crafting.SmeltingRecipe;

final class RecipeApi {
    static void prepare(RegistryAccess lookup) {
        for (var components : BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup)) components.apply();
    }
    static ItemStack remainder(Item item) {
        var remainder = item.getCraftingRemainder();
        return remainder == null ? ItemStack.EMPTY : remainder.create();
    }
    static ItemStack result(SmeltingRecipe recipe, RegistryAccess lookup) { return recipe.assemble(new SingleRecipeInput(ItemStack.EMPTY)); }
    static ItemStack result(CraftingRecipe recipe, RegistryAccess lookup) { return recipe.assemble(CraftingInput.EMPTY); }
}
