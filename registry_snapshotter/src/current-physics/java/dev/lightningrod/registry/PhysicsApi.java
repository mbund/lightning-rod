package dev.lightningrod.registry;

import net.minecraft.util.valueproviders.IntProvider;

final class PhysicsApi {
    static int minimum(IntProvider provider) { return provider.minInclusive(); }
    static int maximum(IntProvider provider) { return provider.maxInclusive(); }
}
