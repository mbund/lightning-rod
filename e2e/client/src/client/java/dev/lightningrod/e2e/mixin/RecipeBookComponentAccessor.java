package dev.lightningrod.e2e.mixin;

import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.screens.recipebook.RecipeBookComponent;
import net.minecraft.client.gui.screens.recipebook.RecipeBookPage;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(RecipeBookComponent.class)
public interface RecipeBookComponentAccessor {
    @Accessor("recipeBookPage")
    RecipeBookPage lightningRod$page();
    @Accessor("searchBox")
    EditBox lightningRod$search();
    @Invoker("checkSearchStringUpdate")
    void lightningRod$updateSearch();
}
