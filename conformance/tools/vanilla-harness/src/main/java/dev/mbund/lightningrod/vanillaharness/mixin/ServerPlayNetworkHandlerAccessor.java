package dev.mbund.lightningrod.vanillaharness.mixin;

import net.minecraft.server.network.ServerPlayNetworkHandler;
import net.minecraft.util.math.Vec3d;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(ServerPlayNetworkHandler.class)
public interface ServerPlayNetworkHandlerAccessor {
    @Accessor("requestedTeleportPos")
    void lightningRodHarnessRequestedTeleportPos(Vec3d position);
}
