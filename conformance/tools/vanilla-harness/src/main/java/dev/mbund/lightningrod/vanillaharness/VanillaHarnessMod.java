package dev.mbund.lightningrod.vanillaharness;

import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;

public final class VanillaHarnessMod implements ModInitializer {
    @Override
    public void onInitialize() {
        if (System.getProperty("mcc.harness.socket") == null) return;
        ServerLifecycleEvents.SERVER_STARTED.register(HarnessController::start);
        ServerLifecycleEvents.SERVER_STOPPED.register(server -> HarnessController.closeActive());
    }
}
