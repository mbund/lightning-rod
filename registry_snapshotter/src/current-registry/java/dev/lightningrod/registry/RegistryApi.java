package dev.lightningrod.registry;

import net.minecraft.resources.ResourceKey;

final class RegistryApi {
    static String name(ResourceKey<?> key) { return key.identifier().toString(); }
}
