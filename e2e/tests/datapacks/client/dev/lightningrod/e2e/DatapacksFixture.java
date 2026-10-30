package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import dev.lightningrod.e2e.mixin.MouseHandlerAccessor;
import net.fabricmc.fabric.api.client.item.v1.ItemTooltipCallback;
import net.minecraft.network.chat.Component;
import org.lwjgl.glfw.GLFW;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.core.BlockPos;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.Registries;
import net.minecraft.tags.TagKey;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.inventory.RecipeBookType;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.Vec3;

final class DatapacksFixture extends Fixture {
    private enum Phase { WAITING, PLAIN, WRONG, PAPER, INPUT, CHARGED, LOG, OVERRIDE, SAVE, MINE, PICKUP, RELOADED_BOOK, RELOADED_REJECT, RELOADED }
    private enum Rejection { MOVE, PREVIEW, ATTEMPT, RETURN }
    private Phase phase = Phase.WAITING;
    private Rejection rejection = Rejection.MOVE;
    private ItemStack tooltipItem = ItemStack.EMPTY;
    private String hoverLabel;
    private int readyJoin;
    private int click;
    private int bookClick;
    private boolean pending;
    private static final BlockPos STONE = new BlockPos(2, 65, 0);

    DatapacksFixture(Recorder recorder) {
        super(recorder);
        ItemTooltipCallback.EVENT.register((stack, context, type, lines) -> {
            tooltipItem = stack.copy();
            var data = stack.get(DataComponents.CUSTOM_DATA);
            lines.add(Component.literal("custom_data: " + (data == null ? "<absent>" : data.copyTag().toString())));
        });
    }

    @Override boolean encrypted() { return true; }

    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }

    @Override void message(String text) {
        if (text.startsWith("fence ")) return;
        switch (text) {
            case "setup" -> phase = Phase.PLAIN;
            case "reloaded" -> phase = Phase.RELOADED_BOOK;
            default -> client.fail("unexpected_datapacks_message_" + text);
        }
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.send("ready");
            return;
        }
        switch (phase) {
            case PLAIN -> {
                if (GuiApi.screen(game) == null) {
                    if (!game.player.getInventory().getItem(3).is(Items.PAPER)) return;
                    GuiApi.screen(game, new InventoryScreen(game.player));
                }
                if (reject(game, 39, "plain_paper_rejected")) phase = Phase.WRONG;
            }
            case WRONG -> {
                if (reject(game, 40, "wrong_charge_rejected")) phase = Phase.PAPER;
            }
            case PAPER -> {
                if (bookPlace(game, true)) phase = Phase.INPUT;
            }
            case INPUT -> {
                if (!hover(game, 1, "matching_paper_nbt")) return;
                phase = Phase.CHARGED;
            }
            case CHARGED -> {
                ItemStack result = game.player.containerMenu.getSlot(0).getItem();
                if (!result.is(Items.DIAMOND) || !charged(result)) return;
                if (!hover(game, 0, "derived_nbt_recipe")) return;
                GameApi.inventoryClick(game, 0, 0, ClickType.QUICK_MOVE);
                client.fence("diamonds");
                phase = Phase.LOG;
            }
            case LOG -> {
                if (!client.fenced("diamonds") || game.player.getInventory().countItem(Items.DIAMOND) != 2) return;
                if (bookPlace(game, false)) phase = Phase.OVERRIDE;
            }
            case OVERRIDE -> {
                ItemStack result = game.player.containerMenu.getSlot(0).getItem();
                if (!result.is(Items.EMERALD) || result.getCount() != 4) return;
                var tag = TagKey.create(Registries.ITEM, GameApi.id("e2e_logs"));
                if (!Items.OAK_LOG.builtInRegistryHolder().is(tag)) { client.fail("missing_loaded_item_tag"); return; }
                if (!hover(game, 0, "overridden_tag_recipe")) return;
                GameApi.inventoryClick(game, 0, 0, ClickType.QUICK_MOVE);
                client.fence("emeralds");
                phase = Phase.SAVE;
            }
            case SAVE -> {
                if (!client.fenced("emeralds") || game.player.getInventory().countItem(Items.EMERALD) != 4) return;
                game.player.closeContainer();
                game.player.getInventory().setSelectedSlot(2);
                phase = Phase.MINE;
            }
            case MINE -> {
                if (!game.level.getBlockState(STONE).isAir()) {
                    var delta = Vec3.atCenterOf(STONE).subtract(game.player.getEyePosition());
                    game.player.setYRot((float)Math.toDegrees(Math.atan2(-delta.x, delta.z)));
                    game.player.setXRot((float)-Math.toDegrees(Math.atan2(delta.y, Math.hypot(delta.x, delta.z))));
                    game.options.keyAttack.setDown(true);
                    return;
                }
                game.options.keyAttack.setDown(false);
                game.player.setPos(2.5, 65, 0.5);
                phase = Phase.PICKUP;
            }
            case PICKUP -> {
                if (game.player.getInventory().countItem(Items.GOLD_INGOT) != 3) return;
                if (!client.screenshot("overridden_block_loot").done()) return;
                client.send("crafted");
                phase = Phase.WAITING;
            }
            case RELOADED_BOOK -> {
                if (game.player.getInventory().countItem(Items.DIAMOND) != 2 || game.player.getInventory().countItem(Items.EMERALD) != 4 || game.player.getInventory().countItem(Items.GOLD_INGOT) != 3) return;
                for (int index = 0; index < game.player.getInventory().getContainerSize(); index++) {
                    ItemStack stack = game.player.getInventory().getItem(index);
                    if (stack.is(Items.DIAMOND) && !charged(stack)) { client.fail("derived_nbt_lost_on_reload"); return; }
                }
                if (game.player.getInventory().countItem(Items.PAPER) != 4) { client.fail("rejected_paper_not_preserved"); return; }
                if (!game.player.getRecipeBook().isFiltering(RecipeBookType.CRAFTING)) { client.fail("recipe_book_filter_lost_on_reload"); return; }
                if (GuiApi.screen(game) == null) GuiApi.screen(game, new InventoryScreen(game.player));
                RecipeBookApi.open(game, true);
                var restoredRecipe = RecipeBookApi.find(game, "diamond", stack -> stack.is(Items.DIAMOND) && charged(stack));
                if (restoredRecipe == null) return;
                if (!hoverAt(game, restoredRecipe.getX() + 10, restoredRecipe.getY() + 10, restoredRecipe.getDisplayStack(), "recipe_book_after_reload")) return;
                RecipeBookApi.click(game, restoredRecipe);
                client.fence("book_wrong_nbt");
                phase = Phase.RELOADED_REJECT;
            }
            case RELOADED_REJECT -> {
                if (!client.fenced("book_wrong_nbt")) return;
                if (!game.player.containerMenu.getSlot(0).getItem().isEmpty()
                    || !game.player.containerMenu.getSlot(1).getItem().isEmpty()
                    || game.player.getInventory().countItem(Items.PAPER) != 4
                    || game.player.getInventory().countItem(Items.DIAMOND) != 2) {
                    client.fail("book_crafted_from_wrong_nbt");
                    return;
                }
                var button = RecipeBookApi.find(game, "diamond", stack -> stack.is(Items.DIAMOND) && charged(stack));
                if (button == null || !hoverAt(game, button.getX() + 10, button.getY() + 10, button.getDisplayStack(), "book_wrong_nbt_rejected")) return;
                RecipeBookApi.open(game, false);
                phase = Phase.RELOADED;
            }
            case RELOADED -> {
                int diamondSlot = -1;
                for (var slot : game.player.containerMenu.slots) if (slot.getItem().is(Items.DIAMOND)) { diamondSlot = slot.index; break; }
                if (diamondSlot < 0 || !hover(game, diamondSlot, "loaded_content_after_reload")) return;
                client.pass("loaded_pack_tags_recipes_nbt_loot_and_reload_verified");
            }
            default -> {}
        }
    }

    private boolean charged(ItemStack stack) {
        var data = stack.get(DataComponents.CUSTOM_DATA);
        return data != null && data.copyTag().getInt("charge").orElse(-1) == 12;
    }

    private boolean bookPlace(Minecraft game, boolean chargedRecipe) {
        RecipeBookApi.open(game, true);
        var button = RecipeBookApi.find(game, chargedRecipe ? "diamond" : "emerald", stack -> chargedRecipe ? stack.is(Items.DIAMOND) && charged(stack) : stack.is(Items.EMERALD) && stack.getCount() == 4);
        if (button == null) return false;
        String label = chargedRecipe ? "charged_book" : "planks_book";
        if (bookClick == 0) {
            if (!hoverAt(game, button.getX() + 10, button.getY() + 10, button.getDisplayStack(), label)) return false;
            RecipeBookApi.filter(game, true);
            RecipeBookApi.click(game, button);
            client.fence(label + "_1");
            bookClick = 1;
            return false;
        }
        if (!client.fenced(label + "_" + bookClick)) return false;
        var input = game.player.containerMenu.getSlot(1).getItem();
        if (!input.is(chargedRecipe ? Items.PAPER : Items.OAK_LOG) || input.getCount() != bookClick) { client.fail(label + "_wrong_placement"); return false; }
        if (chargedRecipe) {
            var data = input.get(DataComponents.CUSTOM_DATA);
            if (data == null || data.copyTag().getInt("charge").orElse(-1) != 7) { client.fail("book_placed_wrong_nbt"); return false; }
            if (bookClick == 1) {
                RecipeBookApi.click(game, button);
                client.fence(label + "_2");
                bookClick = 2;
                return false;
            }
        }
        RecipeBookApi.open(game, false);
        bookClick = 0;
        return true;
    }

    private boolean reject(Minecraft game, int source, String label) {
        switch (rejection) {
            case MOVE -> {
                if (move(game, source, 1)) rejection = Rejection.PREVIEW;
            }
            case PREVIEW -> {
                if (!game.player.containerMenu.getSlot(0).getItem().isEmpty()) { client.fail(label + "_has_output"); return false; }
                if (!hover(game, 1, label)) return false;
                GameApi.inventoryClick(game, 0, 0, ClickType.QUICK_MOVE);
                client.fence(label);
                rejection = Rejection.ATTEMPT;
            }
            case ATTEMPT -> {
                if (!client.fenced(label)) return false;
                ItemStack input = game.player.containerMenu.getSlot(1).getItem();
                if (!input.is(Items.PAPER) || input.getCount() != 2
                    || !game.player.containerMenu.getCarried().isEmpty()
                    || game.player.getInventory().countItem(Items.DIAMOND) != 0
                    || !game.player.containerMenu.getSlot(0).getItem().isEmpty()) {
                    client.fail(label + "_changed_inventory");
                    return false;
                }
                var data = input.get(DataComponents.CUSTOM_DATA);
                if (source == 39 ? data != null : data == null || data.copyTag().getInt("charge").orElse(-1) != 6) {
                    client.fail(label + "_changed_nbt");
                    return false;
                }
                rejection = Rejection.RETURN;
            }
            case RETURN -> {
                if (!move(game, 1, source)) return false;
                rejection = Rejection.MOVE;
                return true;
            }
        }
        return false;
    }

    private boolean hover(Minecraft game, int index, String label) {
        var screen = GuiApi.screen(game);
        if (!(screen instanceof InventoryScreen)) throw new IllegalStateException("inventory screen required");
        var slot = game.player.containerMenu.getSlot(index);
        double x = (screen.width - 176) / 2 + slot.x + 8;
        double y = (screen.height - 166) / 2 + slot.y + 8;
        return hoverAt(game, x, y, slot.getItem(), label);
    }

    private boolean hoverAt(Minecraft game, double x, double y, ItemStack item, String label) {
        if (!label.equals(hoverLabel)) { hoverLabel = label; tooltipItem = ItemStack.EMPTY; }
        var screen = GuiApi.screen(game);
        int[] width = new int[1], height = new int[1];
        GLFW.glfwGetWindowSize(ClientApi.window(game), width, height);
        ((MouseHandlerAccessor)game.mouseHandler).lightningRod$move(ClientApi.window(game), x * width[0] / screen.width, y * height[0] / screen.height);
        if (item.isEmpty() || !ItemStack.isSameItemSameComponents(tooltipItem, item)) return false;
        return client.screenshot(label).done();
    }

    private boolean move(Minecraft game, int source, int destination) {
        String label = "ingredient_" + phase + "_" + source + "_" + destination + "_" + click;
        if (pending) {
            if (!client.fenced(label)) return false;
            pending = false;
            click++;
        }
        if (click == 2) { click = 0; return true; }
        GameApi.inventoryClick(game, click == 0 ? source : destination, 0, ClickType.PICKUP);
        client.fence("ingredient_" + phase + "_" + source + "_" + destination + "_" + click);
        pending = true;
        return false;
    }
}
