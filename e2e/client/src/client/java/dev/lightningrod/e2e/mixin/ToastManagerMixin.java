package dev.lightningrod.e2e.mixin;

import net.minecraft.client.toast.SystemToast;
import net.minecraft.client.toast.Toast;
import net.minecraft.client.toast.ToastManager;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ToastManager.class)
abstract class ToastManagerMixin {
    @Inject(method = "add", at = @At("HEAD"), cancellable = true)
    private void suppressChatWarning(Toast toast, CallbackInfo info) {
        if (toast instanceof SystemToast system && system.getType() == SystemToast.Type.UNSECURE_SERVER_WARNING) info.cancel();
    }
}
