package dev.mbund.lightningrod.conformance.mixin;

import net.minecraft.client.network.Address;
import net.minecraft.client.network.BlockListChecker;
import net.minecraft.client.network.ServerAddress;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(BlockListChecker.class)
public interface BlockListCheckerMixin {
    @Inject(method = "create", at = @At("HEAD"), cancellable = true)
    private static void allowLocalE2eServer(CallbackInfoReturnable<BlockListChecker> callback) {
        callback.setReturnValue(new BlockListChecker() {
            public boolean isAllowed(Address address) { return true; }
            public boolean isAllowed(ServerAddress address) { return true; }
        });
    }
}
