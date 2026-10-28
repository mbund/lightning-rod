package dev.lightningrod.registry;

import com.google.gson.JsonParser;
import com.mojang.serialization.JsonOps;
import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import net.minecraft.world.item.crafting.CraftingRecipe;
import net.minecraft.world.item.crafting.Ingredient;
import net.minecraft.world.item.crafting.ShapedRecipe;
import net.minecraft.world.item.crafting.ShapelessRecipe;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.RegistryOps;
import net.minecraft.server.packs.resources.ResourceManager;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.Recipe;
import net.minecraft.world.item.crafting.SmeltingRecipe;
import net.minecraft.world.level.block.entity.FuelValues;

final class RecipeSnapshot {
    static void write(Path path, ResourceManager resources, RegistryAccess lookup) throws Exception {
        Files.createDirectories(path.toAbsolutePath().getParent());
        RecipeApi.prepare(lookup);
        var fuels = FuelValues.vanillaBurnTimes(lookup, FeatureFlags.DEFAULT_FLAGS);
        var recipes = new ArrayList<SmeltingRecipe>();
        var crafting = new ArrayList<CraftingRecipe>();
        var ops = RegistryOps.create(JsonOps.INSTANCE, lookup);
        var entries = resources.listResources("recipe", id -> id.toString().endsWith(".json"));
        for (var entry : entries.entrySet().stream().sorted(Comparator.comparing(e -> e.getKey().toString())).toList()) {
            try (var reader = entry.getValue().openAsReader()) {
                var json = JsonParser.parseReader(reader);
                var type = json.getAsJsonObject().get("type").getAsString();
                if (!List.of("minecraft:smelting", "minecraft:crafting_shaped", "minecraft:crafting_shapeless").contains(type)) continue;
                var recipe = Recipe.CODEC.parse(ops, json).getOrThrow();
                if (recipe instanceof SmeltingRecipe smelting) recipes.add(smelting);
                else if (recipe instanceof CraftingRecipe craft) crafting.add(craft);
                else throw new IllegalStateException("Invalid recipe");
            }
        }
        try (var out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(path)))) {
            out.write("LRRCP001".getBytes(StandardCharsets.US_ASCII));
            out.writeInt(BuiltInRegistries.ITEM.size());
            for (var item : BuiltInRegistries.ITEM) {
                string(out, BuiltInRegistries.ITEM.getKey(item).toString());
                out.writeInt(fuels.burnDuration(new ItemStack(item)));
                var remainder = RecipeApi.remainder(item);
                string(out, remainder.isEmpty() ? "" : BuiltInRegistries.ITEM.getKey(remainder.getItem()).toString());
            }
            out.writeInt(recipes.stream().mapToInt(r -> (int) r.input().items().count()).sum());
            for (var recipe : recipes) {
                var result = RecipeApi.result(recipe, lookup);
                for (var input : recipe.input().items().toList()) {
                    string(out, BuiltInRegistries.ITEM.getKey(input.value()).toString());
                    string(out, BuiltInRegistries.ITEM.getKey(result.getItem()).toString());
                    out.writeInt(result.getCount());
                    out.writeInt(recipe.cookingTime());
                    out.writeFloat(recipe.experience());
                }
            }
            out.writeInt(crafting.size());
            for (var recipe : crafting) {
                var shaped = recipe instanceof ShapedRecipe;
                out.writeByte(shaped ? ((ShapedRecipe) recipe).getWidth() : 0);
                out.writeByte(shaped ? ((ShapedRecipe) recipe).getHeight() : 0);
                List<Optional<Ingredient>> ingredients = shaped ? ((ShapedRecipe) recipe).getIngredients()
                    : recipe.placementInfo().ingredients().stream().map(Optional::of).toList();
                out.writeByte(ingredients.size());
                var result = RecipeApi.result(recipe, lookup);
                string(out, BuiltInRegistries.ITEM.getKey(result.getItem()).toString());
                out.writeInt(result.getCount());
                for (var ingredient : ingredients) {
                    var items = ingredient.isEmpty() ? List.<net.minecraft.core.Holder<net.minecraft.world.item.Item>>of() : ingredient.get().items().toList();
                    out.writeShort(items.size());
                    for (var item : items) string(out, BuiltInRegistries.ITEM.getKey(item.value()).toString());
                }
            }
        }
    }

    private static void string(DataOutputStream out, String text) throws Exception {
        var bytes = text.getBytes(StandardCharsets.UTF_8);
        out.writeShort(bytes.length);
        out.write(bytes);
    }
}
