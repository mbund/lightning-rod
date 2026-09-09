package dev.mbund.lightningrod.vanillaharness;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
/** Vanilla endpoint observer; it changes no server state or gameplay policy. */
public final class VanillaHarnessMod implements ModInitializer {
 @Override public void onInitialize() { ServerLifecycleEvents.SERVER_STOPPING.register(server -> Recorder.instance().write()); Recorder.instance().configure(); }
}
