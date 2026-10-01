package dev.lightningrod.e2e;

import java.io.File;
import java.util.function.Consumer;
import net.minecraft.SharedConstants;
import net.minecraft.client.Screenshot;
import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.network.chat.Component;

final class ClientCompatibility {
    static String version() {
        return SharedConstants.getCurrentVersion().name();
    }

    static void screenshot(File directory, String name, RenderTarget target, Consumer<Component> result) {
        Screenshot.grab(directory, name, target, 1, result);
    }

}
