package dev.mbund.lightningrod.vanillaharness.mixin;

import net.minecraft.server.PlayerManager;
import net.minecraft.server.world.ServerWorld;
import net.minecraft.util.math.ChunkPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * A controlled tick cannot wait for a future tick to promote a login spawn
 * chunk. Fixtures load their required chunks directly, so this one transport
 * bootstrap wait is deliberately omitted while the rest of Vanilla's player
 * connection path remains intact.
 */
@Mixin(PlayerManager.class)
public abstract class PlayerManagerMixin {
    @Redirect(
        method = "onPlayerConnect",
        at = @At(
            value = "INVOKE",
            target = "Lnet/minecraft/server/world/ServerWorld;method_72079(Lnet/minecraft/util/math/ChunkPos;I)V"
        )
    )
    private void lightningRodHarnessSkipSpawnChunkWait(ServerWorld world, ChunkPos chunk, int level) {
    }
}
