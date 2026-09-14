package dev.lightningrod.e2e.mixin;

import dev.lightningrod.e2e.Recorder;
import net.minecraft.client.MinecraftClient;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(MinecraftClient.class)
abstract class MinecraftClientMixin {
    @Inject(method = "render", at = @At("RETURN"))
    private void rendered(boolean tick, CallbackInfo info) {
        Recorder.instance().rendered((MinecraftClient) (Object) this);
    }
}
