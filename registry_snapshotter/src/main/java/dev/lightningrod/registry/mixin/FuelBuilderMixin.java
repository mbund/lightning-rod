package dev.lightningrod.registry.mixin;

import dev.lightningrod.registry.FuelSnapshot;

import net.minecraft.tags.TagKey;
import net.minecraft.world.item.Item;
import net.minecraft.world.level.ItemLike;
import net.minecraft.world.level.block.entity.FuelValues;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(FuelValues.Builder.class)
abstract class FuelBuilderMixin {
    @Inject(method = "add(Lnet/minecraft/world/level/ItemLike;I)Lnet/minecraft/world/level/block/entity/FuelValues$Builder;", at = @At("HEAD"))
    private void item(ItemLike item, int ticks, CallbackInfoReturnable<FuelValues.Builder> callback) { FuelSnapshot.item(item, ticks); }

    @Inject(method = "add(Lnet/minecraft/tags/TagKey;I)Lnet/minecraft/world/level/block/entity/FuelValues$Builder;", at = @At("HEAD"))
    private void tag(TagKey<Item> tag, int ticks, CallbackInfoReturnable<FuelValues.Builder> callback) { FuelSnapshot.tag(tag, ticks); }

    @Inject(method = "remove", at = @At("HEAD"))
    private void remove(TagKey<Item> tag, CallbackInfoReturnable<FuelValues.Builder> callback) { FuelSnapshot.remove(tag); }

    @Inject(method = { "add(Lnet/minecraft/world/level/ItemLike;I)Lnet/minecraft/world/level/block/entity/FuelValues$Builder;", "add(Lnet/minecraft/tags/TagKey;I)Lnet/minecraft/world/level/block/entity/FuelValues$Builder;", "remove" }, at = @At("RETURN"))
    private void end(CallbackInfoReturnable<FuelValues.Builder> callback) { FuelSnapshot.end(); }
}
