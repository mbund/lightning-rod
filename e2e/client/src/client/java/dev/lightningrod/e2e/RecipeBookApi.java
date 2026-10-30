package dev.lightningrod.e2e;

import java.util.function.Predicate;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.ImageButton;
import net.minecraft.client.gui.screens.recipebook.RecipeBookComponent;
import net.minecraft.client.gui.screens.recipebook.RecipeButton;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.inventory.RecipeBookType;
import dev.lightningrod.e2e.mixin.RecipeBookFilterAccessor;
import dev.lightningrod.e2e.mixin.RecipeBookScreenAccessor;
import dev.lightningrod.e2e.mixin.RecipeBookComponentAccessor;
import dev.lightningrod.e2e.mixin.RecipeBookPageAccessor;

final class RecipeBookApi {
    static RecipeBookComponent<?> book(Minecraft game) {
        return ((RecipeBookScreenAccessor)GuiApi.screen(game)).lightningRod$recipeBook();
    }

    static void open(Minecraft game, boolean visible) {
        if (book(game).isVisible() == visible) return;
        var screen = GuiApi.screen(game);
        for (var child : screen.children()) {
            if (child instanceof ImageButton button && button.visible && button.active) {
                ClientApi.click(screen, button.getX() + button.getWidth() / 2.0, button.getY() + button.getHeight() / 2.0);
                if (book(game).isVisible() == visible) return;
            }
        }
        throw new IllegalStateException("recipe book toggle missing");
    }

    static void filter(Minecraft game, boolean craftable) {
        var filter = ((RecipeBookFilterAccessor)book(game)).lightningRod$filter();
        if (game.player.getRecipeBook().isFiltering(RecipeBookType.CRAFTING) == craftable) return;
        ClientApi.click(GuiApi.screen(game), filter.getX() + filter.getWidth() / 2.0, filter.getY() + filter.getHeight() / 2.0);
    }

    static RecipeButton find(Minecraft game, String search, Predicate<ItemStack> matches) {
        var component = (RecipeBookComponentAccessor)book(game);
        var box = component.lightningRod$search();
        if (!box.getValue().equals(search)) {
            box.setValue(search);
            component.lightningRod$updateSearch();
        }
        var page = (RecipeBookPageAccessor)component.lightningRod$page();
        for (var button : page.lightningRod$buttons()) {
            if (button.visible && matches.test(button.getDisplayStack())) return button;
        }
        return null;
    }

    static void click(Minecraft game, RecipeButton button) {
        ClientApi.click(GuiApi.screen(game), button.getX() + button.getWidth() / 2.0, button.getY() + button.getHeight() / 2.0);
    }
}
