package dev.lightningrod.e2e.mixin;

import net.minecraft.client.gui.components.StateSwitchingButton;
import net.minecraft.client.gui.screens.recipebook.RecipeBookComponent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(RecipeBookComponent.class)
public interface RecipeBookFilterAccessor {
    @Accessor("filterButton")
    StateSwitchingButton lightningRod$filter();
}
