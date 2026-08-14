package dev.mbund.lightningrod.vanillaharness.mixin;

import net.minecraft.entity.ItemEntity;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(ItemEntity.class)
public interface ItemEntityAccessor {
    @Accessor("itemAge")
    void lightningRodHarnessSetItemAge(int age);
}
