package dev.lightningrod.registry;

import net.minecraft.util.valueproviders.IntProvider;

final class PhysicsApi {
    static int minimum(IntProvider provider) { return provider.getMinValue(); }
    static int maximum(IntProvider provider) { return provider.getMaxValue(); }
}
