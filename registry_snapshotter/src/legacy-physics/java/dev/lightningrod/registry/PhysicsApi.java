package dev.lightningrod.registry;

import net.minecraft.util.valueproviders.IntProvider;

final class PhysicsApi {
    static int minimum(IntProvider provider) { return provider.getMinValue(); }
    static int maximum(IntProvider provider) { return provider.getMaxValue(); }
    // Releases before 26.1 name the tag directly.
    static String resistedTag(net.minecraft.world.item.component.DamageResistant resistant) { return resistant.types().location().toString(); }
}
