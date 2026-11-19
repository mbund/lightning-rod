package dev.lightningrod.registry;

import net.minecraft.util.valueproviders.IntProvider;

final class PhysicsApi {
    static int minimum(IntProvider provider) { return provider.minInclusive(); }
    static int maximum(IntProvider provider) { return provider.maxInclusive(); }
    // Since 26.1 a holder set, which every vanilla item fills from a tag.
    static String resistedTag(net.minecraft.world.item.component.DamageResistant resistant) {
        return resistant.types().unwrapKey().orElseThrow(() -> new IllegalStateException("Damage resistance without a tag")).location().toString();
    }
}
