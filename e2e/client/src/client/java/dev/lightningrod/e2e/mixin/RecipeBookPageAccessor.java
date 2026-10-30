package dev.lightningrod.e2e.mixin;

import java.util.List;
import net.minecraft.client.gui.screens.recipebook.RecipeBookPage;
import net.minecraft.client.gui.screens.recipebook.RecipeButton;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(RecipeBookPage.class)
public interface RecipeBookPageAccessor {
    @Accessor("buttons")
    List<RecipeButton> lightningRod$buttons();
}
