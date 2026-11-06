package dev.lightningrod.registry;

import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.shapes.EntityCollisionContext;

final class SpawnContext extends EntityCollisionContext {
    SpawnContext() { super(false, false, 0, ItemStack.EMPTY, false, null); }
}
