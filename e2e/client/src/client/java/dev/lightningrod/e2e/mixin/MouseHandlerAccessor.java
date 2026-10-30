package dev.lightningrod.e2e.mixin;

import net.minecraft.client.MouseHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(MouseHandler.class)
public interface MouseHandlerAccessor {
    @Invoker("onMove")
    void lightningRod$move(long window, double x, double y);
}
