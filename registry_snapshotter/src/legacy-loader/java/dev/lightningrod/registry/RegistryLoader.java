package dev.lightningrod.registry;

import net.minecraft.core.RegistryAccess;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.packs.resources.MultiPackResourceManager;

final class RegistryLoader {
    static RegistryAccess.Frozen load(MultiPackResourceManager resources, RegistryAccess.Frozen builtin) {
        return RegistryDataLoader.load(resources, builtin.listRegistries().toList(), RegistryDataLoader.WORLDGEN_REGISTRIES);
    }
}
