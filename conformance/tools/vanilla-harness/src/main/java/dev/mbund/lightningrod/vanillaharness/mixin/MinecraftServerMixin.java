package dev.mbund.lightningrod.vanillaharness.mixin;

import dev.mbund.lightningrod.vanillaharness.HarnessController;
import net.minecraft.server.MinecraftServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.function.BooleanSupplier;

@Mixin(MinecraftServer.class)
public abstract class MinecraftServerMixin {
    @Inject(method = "tick", at = @At("HEAD"), cancellable = true)
    private void lightningRodHarnessBeforeTick(BooleanSupplier shouldKeepTicking, CallbackInfo callback) {
        if (HarnessController.beforeTick((MinecraftServer) (Object) this)) callback.cancel();
    }

    @Inject(method = "tick", at = @At("TAIL"))
    private void lightningRodHarnessAfterTick(BooleanSupplier shouldKeepTicking, CallbackInfo callback) {
        HarnessController.afterTick((MinecraftServer) (Object) this);
    }
}
