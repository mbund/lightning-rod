package dev.lightningrod.registry;

import net.minecraft.core.RegistryAccess;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.CraftingInput;
import net.minecraft.world.item.crafting.CraftingRecipe;
import net.minecraft.world.item.crafting.SingleRecipeInput;
import net.minecraft.world.item.crafting.SmeltingRecipe;

final class RecipeApi {
    static void prepare(RegistryAccess lookup) {}
    static ItemStack remainder(Item item) { return item.getCraftingRemainder(); }
    static ItemStack result(SmeltingRecipe recipe, RegistryAccess lookup) { return recipe.assemble(new SingleRecipeInput(ItemStack.EMPTY), lookup); }
    static ItemStack result(CraftingRecipe recipe, RegistryAccess lookup) { return recipe.assemble(CraftingInput.EMPTY, lookup); }
}
