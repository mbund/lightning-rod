package dev.lightningrod.e2e.mixin;

import net.minecraft.client.gui.components.CycleButton;
import net.minecraft.client.gui.screens.recipebook.RecipeBookComponent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(RecipeBookComponent.class)
public interface RecipeBookFilterAccessor {
    @Accessor("filterButton")
    CycleButton<Boolean> lightningRod$filter();
}
