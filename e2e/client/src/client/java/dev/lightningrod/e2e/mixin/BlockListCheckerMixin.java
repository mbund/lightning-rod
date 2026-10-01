package dev.lightningrod.e2e.mixin;

import net.minecraft.client.multiplayer.resolver.AddressCheck;
import net.minecraft.client.multiplayer.resolver.ResolvedServerAddress;
import net.minecraft.client.multiplayer.resolver.ServerAddress;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(AddressCheck.class)
public interface BlockListCheckerMixin {
    @Inject(method = "createFromService", at = @At("HEAD"), cancellable = true)
    private static void allowLocalE2eServer(CallbackInfoReturnable<AddressCheck> callback) {
        callback.setReturnValue(new AddressCheck() {
            public boolean isAllowed(ResolvedServerAddress address) { return true; }
            public boolean isAllowed(ServerAddress address) { return true; }
        });
    }
}
